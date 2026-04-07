// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * AG-UI Agent Service
 *
 * Main orchestrator for the AG-UI protocol. Handles incoming requests,
 * emits AG-UI events via SSE, and coordinates LLM calls with UI generation.
 *
 * Routing (via IntentRouter):
 *   blocked          → 403, no LLM call
 *   vllm             → @sap-ai-sdk/vllm VllmChatClient
 *   pal              → PalClient → ai-core-pal MCP :8084
 *   rag              → HANAVectorStore + OrchestrationClient
 *   aicore-streaming → ai-core-streaming MCP :9190 stream_complete
 */

import * as cds from '@sap/cds';
import type { ServerResponse } from 'http';
import {
  AgUiEventType,
  AgUiRunRequest,
  AgUiToolResultRequest,
  A2UiSchema,
  GenUiEventNames,
  serializeEvent,
  createErrorFrame,
  createDoneSentinel,
} from './event-types';
import { SchemaGenerator, createLoadingSchema, createErrorSchema } from './schema-generator';
import { GENERATE_SAC_WIDGET_FUNCTION } from './sac-schema-generator';
import { ToolHandler, ToolRegistry } from './tool-handler';
import { SAC_TOOLS } from './sac-tool-handler';
import { getTracer, SpanStatusCode } from '../../src/telemetry/tracer';
import { IntentRouter, RouteDecision } from './intent-router';
import { PalClient } from './pal-client';

const LOG = (cds as any).log('ag-ui-agent') as {
  debug: (...args: unknown[]) => void;
  info: (...args: unknown[]) => void;
  warn: (...args: unknown[]) => void;
  error: (...args: unknown[]) => void;
};

// =============================================================================
// Types
// =============================================================================

/** Agent service configuration */
export interface AgUiAgentConfig {
  chatModelName: string;
  uiModelName?: string;
  resourceGroup: string;
  enableRag?: boolean;
  ragTable?: string;
  ragEmbeddingColumn?: string;
  ragContentColumn?: string;
  embeddingModelName?: string;
  /** vLLM endpoint for confidential data route (default: http://localhost:9180) */
  vllmEndpoint?: string;
  /** vLLM model name to use (default: Qwen/Qwen3.5-35B) */
  vllmModel?: string;
  /** ai-core-pal MCP endpoint for analytics route (default: http://localhost:8084/mcp) */
  palEndpoint?: string;
  /** ai-core-streaming MCP endpoint for default route (default: http://localhost:9190/mcp) */
  mcpEndpoint?: string;
  /** Service identifier used for routing policy lookup */
  serviceId?: string;
  /** Security classification: public | internal | confidential | restricted */
  securityClass?: string;
  /** Additional confidential keywords beyond defaults */
  confidentialKeywords?: string[];
  /** Additional PAL analytics keywords beyond defaults */
  palKeywords?: string[];
}

/** Session state */
interface AgentSession {
  threadId: string;
  runId: string;
  messages: Array<{ role: string; content: string }>;
  currentSchema?: A2UiSchema;
  state: Record<string, unknown>;
  createdAt: number;
  lastActivityAt: number;
}

// =============================================================================
// AG-UI Agent Service
// =============================================================================

export class AgUiAgentService {
  private config: AgUiAgentConfig;
  private schemaGenerator: SchemaGenerator;
  private toolHandler: ToolHandler;
  private intentRouter: IntentRouter;
  private palClient: PalClient;
  private static readonly MAX_SESSIONS = 1000;
  private static readonly SESSION_TTL_MS = 30 * 60 * 1000; // 30 minutes
  private static readonly MAX_SESSION_MESSAGES = 50;
  private sessions = new Map<string, AgentSession>();
  private llmPlugin: unknown;

  constructor(config: AgUiAgentConfig, llmPlugin: unknown) {
    this.config = config;
    this.llmPlugin = llmPlugin;
    this.schemaGenerator = new SchemaGenerator({
      modelName: config.uiModelName ?? config.chatModelName,
      resourceGroup: config.resourceGroup,
    });
    this.toolHandler = new ToolHandler();
    for (const tool of SAC_TOOLS) {
      this.toolHandler.getRegistry().register(tool);
    }
    if (config.serviceId === 'sac-ai-widget') {
      this.toolHandler.getRegistry().register(GENERATE_SAC_WIDGET_FUNCTION);
    }
    this.intentRouter = new IntentRouter({
      vllmEndpoint: config.vllmEndpoint,
      palEndpoint: config.palEndpoint,
      mcpEndpoint: config.mcpEndpoint,
      confidentialKeywords: config.confidentialKeywords,
      palKeywords: config.palKeywords,
    });
    this.palClient = new PalClient(
      config.palEndpoint ?? 'http://localhost:8084/mcp'
    );
  }

  /** Evict expired sessions and enforce max session count. */
  private evictStaleSessions(): void {
    const now = Date.now();
    for (const [id, session] of this.sessions) {
      if (now - session.lastActivityAt > AgUiAgentService.SESSION_TTL_MS) {
        this.sessions.delete(id);
      }
    }
    // If still over limit, evict oldest first
    if (this.sessions.size > AgUiAgentService.MAX_SESSIONS) {
      const sorted = [...this.sessions.entries()].sort((a, b) => a[1].lastActivityAt - b[1].lastActivityAt);
      const toEvict = sorted.slice(0, this.sessions.size - AgUiAgentService.MAX_SESSIONS);
      for (const [id] of toEvict) {
        this.sessions.delete(id);
      }
    }
  }

  getToolRegistry(): ToolRegistry {
    return this.toolHandler.getRegistry();
  }

  async handleRunRequest(request: AgUiRunRequest, httpRes: ServerResponse): Promise<void> {
    const span = getTracer().startSpan('ag-ui-agent.handleRunRequest');
    const threadId = request.threadId ?? this.generateId('thread');
    const runId = request.runId ?? this.generateId('run');

    httpRes.setHeader('Content-Type', 'text/event-stream');
    httpRes.setHeader('Cache-Control', 'no-cache');
    httpRes.setHeader('X-Accel-Buffering', 'no');
    httpRes.setHeader('Connection', 'keep-alive');
    httpRes.flushHeaders();

    try {
      // Evict stale sessions periodically
      this.evictStaleSessions();

      let session = this.sessions.get(threadId);
      if (!session) {
        session = { threadId, runId, messages: [], state: {}, createdAt: Date.now(), lastActivityAt: Date.now() };
        this.sessions.set(threadId, session);
      }
      session.runId = runId;
      session.lastActivityAt = Date.now();

      // Validate messages structure before processing
      if (!Array.isArray(request.messages) || request.messages.length === 0) {
        throw new Error('request.messages must be a non-empty array');
      }
      for (const msg of request.messages) {
        if (!msg || typeof msg.role !== 'string' || typeof msg.content !== 'string') {
          throw new Error('Each message must have string "role" and "content" fields');
        }
        session.messages.push({ role: msg.role, content: msg.content });
      }

      // Cap session messages to rolling window to prevent unbounded memory growth
      if (session.messages.length > AgUiAgentService.MAX_SESSION_MESSAGES) {
        session.messages = session.messages.slice(-AgUiAgentService.MAX_SESSION_MESSAGES);
      }

      const userMessage = request.messages.find(m => m.role === 'user')?.content ?? '';

      // Routing decision
      const forceBackend = (request as any).forceBackend;
      const route: RouteDecision = this.intentRouter.classify(userMessage, {
        model: this.config.chatModelName,
        serviceId: this.config.serviceId,
        securityClass: this.config.securityClass,
        forceBackend,
        enableRag: this.config.enableRag && !!this.config.ragTable,
      });

      LOG.info(`AG-UI routing decision: ${route.backend} — ${route.reason}`);
      span.setAttribute('ag-ui.route.backend', route.backend);
      span.setAttribute('ag-ui.route.reason', route.reason);

      // Blocked — emit error and exit
      if (route.backend === 'blocked') {
        httpRes.statusCode = 403;
        this.writeEvent(httpRes, AgUiEventType.RUN_ERROR, {
          runId, message: `Request blocked: ${route.reason}`, code: 'REQUEST_BLOCKED',
        });
        httpRes.write(createErrorFrame('REQUEST_BLOCKED', route.reason));
        httpRes.end();
        span.setStatus({ code: SpanStatusCode.ERROR, message: route.reason });
        span.end();
        return;
      }

      // RUN_STARTED
      this.writeEvent(httpRes, AgUiEventType.RUN_STARTED, { runId, threadId });

      // Loading UI
      this.writeEvent(httpRes, AgUiEventType.CUSTOM, {
        name: GenUiEventNames.UI_SCHEMA_SNAPSHOT,
        value: createLoadingSchema('Generating UI...'),
        runId, threadId,
      });

      this.writeEvent(httpRes, AgUiEventType.STEP_STARTED, { stepName: 'generate_ui', runId, threadId });

      let schema: A2UiSchema;

      switch (route.backend) {
        case 'vllm':
          schema = await this.generateSchemaViaVllm(userMessage, session, httpRes, runId, threadId);
          break;
        case 'pal':
          schema = await this.generateSchemaViaPal(userMessage, session, httpRes, runId, threadId);
          break;
        case 'rag':
          schema = await this.generateSchemaWithRag(userMessage, session, httpRes, runId, threadId);
          break;
        case 'aicore-streaming':
          schema = await this.generateSchemaViaAicoreStreaming(userMessage, session, httpRes, runId, threadId);
          break;
        default:
          schema = await this.generateSchemaDirectly(userMessage, session);
      }

      session.currentSchema = schema;

      this.writeEvent(httpRes, AgUiEventType.STEP_FINISHED, { stepName: 'generate_ui', runId, threadId });
      this.writeEvent(httpRes, AgUiEventType.CUSTOM, {
        name: GenUiEventNames.UI_SCHEMA_SNAPSHOT,
        value: schema,
        runId, threadId,
      });
      this.writeEvent(httpRes, AgUiEventType.RUN_FINISHED, { runId, threadId });

      httpRes.write(createDoneSentinel());
      span.setStatus({ code: SpanStatusCode.OK });

    } catch (e) {
      const error = e as Error;
      LOG.error('AG-UI run failed:', error);
      span.recordException(error);

      this.writeEvent(httpRes, AgUiEventType.RUN_ERROR, { runId, message: error.message, code: 'AGENT_ERROR' });
      this.writeEvent(httpRes, AgUiEventType.CUSTOM, {
        name: GenUiEventNames.UI_SCHEMA_SNAPSHOT,
        value: createErrorSchema(error.message),
        runId, threadId: request.threadId ?? 'unknown',
      });

      httpRes.write(createErrorFrame('AGENT_ERROR', error.message));
    } finally {
      httpRes.end();
      span.end();
    }
  }

  async handleToolResult(request: AgUiToolResultRequest): Promise<void> {
    await this.toolHandler.processToolResult(request);
  }

  async streamTextResponse(
    messages: Array<{ role: string; content: string }>,
    httpRes: ServerResponse,
    threadId: string,
    runId: string
  ): Promise<void> {
    httpRes.setHeader('Content-Type', 'text/event-stream');
    httpRes.setHeader('Cache-Control', 'no-cache');
    httpRes.setHeader('Connection', 'keep-alive');
    httpRes.flushHeaders();

    const messageId = this.generateId('msg');

    try {
      this.writeEvent(httpRes, AgUiEventType.TEXT_MESSAGE_START, { messageId, role: 'assistant', runId, threadId });

      const response = await (this.llmPlugin as any).getChatCompletionWithConfig(
        { modelName: this.config.chatModelName, resourceGroup: this.config.resourceGroup },
        { messages }
      );

      const content = response?.getContent?.() ?? String(response);
      const chunkSize = 50;
      for (let i = 0; i < content.length; i += chunkSize) {
        this.writeEvent(httpRes, AgUiEventType.TEXT_MESSAGE_CONTENT, {
          messageId, delta: content.substring(i, i + chunkSize), runId, threadId,
        });
      }

      this.writeEvent(httpRes, AgUiEventType.TEXT_MESSAGE_END, { messageId, runId, threadId });
    } catch (e) {
      httpRes.write(createErrorFrame('STREAM_ERROR', (e as Error).message));
    } finally {
      httpRes.write(createDoneSentinel());
      httpRes.end();
    }
  }

  getSession(threadId: string): AgentSession | undefined {
    return this.sessions.get(threadId);
  }

  clearSession(threadId: string): void {
    this.sessions.delete(threadId);
  }

  health(): { status: string; service: string; activeSessions: number; timestamp: number } {
    return {
      status: 'healthy',
      service: 'ag-ui-agent',
      activeSessions: this.sessions.size,
      timestamp: Date.now(),
    };
  }

  // ---------------------------------------------------------------------------
  // Route B: vLLM (confidential data)
  // Uses @sap-ai-sdk/vllm VllmChatClient when available, falls back to fetch
  // ---------------------------------------------------------------------------

  private async generateSchemaViaVllm(
    userMessage: string,
    session: AgentSession,
    httpRes: ServerResponse,
    runId: string,
    threadId: string
  ): Promise<A2UiSchema> {
    const vllmEndpoint = this.config.vllmEndpoint ?? 'http://localhost:9180';
    const model = this.config.vllmModel ?? 'Qwen/Qwen3.5-35B';

    this.writeEvent(httpRes, AgUiEventType.STEP_STARTED, { stepName: 'vllm_chat', runId, threadId });

    let vllmClient: any;
    try {
      const { VllmChatClient } = await import('@sap-ai-sdk/vllm' as string);
      vllmClient = new VllmChatClient({ endpoint: vllmEndpoint, model });
    } catch {
      vllmClient = null;
    }

    let content: string;
    if (vllmClient) {
      const messages = [
        { role: 'system', content: 'You are a helpful assistant for confidential data processing.' },
        ...session.messages.slice(-6),
        { role: 'user', content: userMessage },
      ];
      const response = await vllmClient.chat(messages, { maxTokens: 2048, temperature: 0.7 });
      content = response?.choices?.[0]?.message?.content ?? '';
    } else {
      // Fallback: raw HTTP to vLLM OpenAI-compat endpoint
      const vllmAbort = new AbortController();
      const vllmTimeout = setTimeout(() => vllmAbort.abort(), 60_000);
      const resp = await fetch(`${vllmEndpoint}/v1/chat/completions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        signal: vllmAbort.signal,
        body: JSON.stringify({
          model,
          messages: [
            { role: 'system', content: 'You are a helpful assistant for confidential data processing.' },
            { role: 'user', content: userMessage },
          ],
          max_tokens: 2048,
          temperature: 0.7,
        }),
      });
      clearTimeout(vllmTimeout);
      const json = await resp.json() as any;
      content = json?.choices?.[0]?.message?.content ?? '';
    }

    this.writeEvent(httpRes, AgUiEventType.STEP_FINISHED, { stepName: 'vllm_chat', runId, threadId });

    // Generate UI schema via SchemaGenerator using the vLLM response as context
    const intentWithContext = content
      ? `${userMessage}\n\nAssistant context (from on-premise model):\n${content}`
      : userMessage;
    const result = await this.schemaGenerator.generateSchema(
      {
        userIntent: intentWithContext,
        context: { availableData: session.state, previousUI: session.currentSchema },
      },
      this.llmPlugin as any
    );
    return result.schema;
  }

  // ---------------------------------------------------------------------------
  // Route C: PAL analytics (ai-core-pal MCP)
  // ---------------------------------------------------------------------------

  private async generateSchemaViaPal(
    userMessage: string,
    session: AgentSession,
    httpRes: ServerResponse,
    runId: string,
    threadId: string
  ): Promise<A2UiSchema> {
    this.writeEvent(httpRes, AgUiEventType.STEP_STARTED, { stepName: 'pal_search', runId, threadId });
    const palTable = (session.state['hanaTable'] as string | undefined);
    const schema = await this.palClient.generatePalTableSchema(userMessage, palTable);
    this.writeEvent(httpRes, AgUiEventType.STEP_FINISHED, { stepName: 'pal_search', runId, threadId });
    return schema;
  }

  // ---------------------------------------------------------------------------
  // Route D: HANA RAG (HANAVectorStore + OrchestrationClient)
  // ---------------------------------------------------------------------------

  private async generateSchemaWithRag(
    userMessage: string,
    session: AgentSession,
    httpRes: ServerResponse,
    runId: string,
    threadId: string
  ): Promise<A2UiSchema> {
    const plugin = this.llmPlugin as any;

    this.writeEvent(httpRes, AgUiEventType.STEP_STARTED, { stepName: 'generate_embedding', runId, threadId });
    const embeddingResponse = await plugin.getEmbeddingWithConfig(
      { modelName: this.config.embeddingModelName ?? 'text-embedding-ada-002', resourceGroup: this.config.resourceGroup },
      userMessage
    );
    const embedding = embeddingResponse.getEmbeddings()[0].embedding;
    this.writeEvent(httpRes, AgUiEventType.STEP_FINISHED, { stepName: 'generate_embedding', runId, threadId });

    this.writeEvent(httpRes, AgUiEventType.STEP_STARTED, { stepName: 'similarity_search', runId, threadId });
    const similarDocs = await plugin.similaritySearch(
      this.config.ragTable!,
      this.config.ragEmbeddingColumn!,
      this.config.ragContentColumn!,
      embedding,
      'COSINE_SIMILARITY',
      3
    );
    this.writeEvent(httpRes, AgUiEventType.STEP_FINISHED, { stepName: 'similarity_search', runId, threadId });

    const context = similarDocs?.map((d: any) => d.PAGE_CONTENT).join('\n\n') ?? '';
    const result = await this.schemaGenerator.generateSchema(
      { userIntent: `${userMessage}\n\nContext from knowledge base:\n${context}`, context: { availableData: session.state } },
      plugin
    );
    return result.schema;
  }

  // ---------------------------------------------------------------------------
  // Route E: ai-core-streaming MCP (default: public/internal)
  // Calls stream_complete tool via MCP JSON-RPC
  // ---------------------------------------------------------------------------

  private async generateSchemaViaAicoreStreaming(
    userMessage: string,
    session: AgentSession,
    httpRes: ServerResponse,
    runId: string,
    threadId: string
  ): Promise<A2UiSchema> {
    const mcpEndpoint = this.config.mcpEndpoint ?? 'http://localhost:9190/mcp';

    this.writeEvent(httpRes, AgUiEventType.STEP_STARTED, { stepName: 'aicore_stream', runId, threadId });

    let mcpClient: any;
    try {
      const { AISdkMcpClient } = await import('@sap-ai-sdk/mcp-server' as string);
      mcpClient = new AISdkMcpClient({ endpoint: mcpEndpoint });
    } catch {
      mcpClient = null;
    }

    let content: string;
    if (mcpClient) {
      const result = await mcpClient.callTool('stream_complete', {
        messages: JSON.stringify([
          { role: 'system', content: 'You are an AI assistant powered by SAP AI Core.' },
          { role: 'user', content: userMessage },
        ]),
        max_tokens: 4096,
        temperature: 0.7,
        stream: false,
      });
      content = result?.content ?? result?.text ?? String(result);
    } else {
      // Fallback: raw MCP JSON-RPC call
      const body = {
        jsonrpc: '2.0',
        id: 1,
        method: 'tools/call',
        params: {
          name: 'stream_complete',
          arguments: {
            messages: JSON.stringify([
              { role: 'system', content: 'You are an AI assistant powered by SAP AI Core.' },
              { role: 'user', content: userMessage },
            ]),
            max_tokens: 4096,
            temperature: 0.7,
            stream: false,
          },
        },
      };
      const mcpAbort = new AbortController();
      const mcpTimeout = setTimeout(() => mcpAbort.abort(), 60_000);
      const resp = await fetch(mcpEndpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        signal: mcpAbort.signal,
        body: JSON.stringify(body),
      });
      clearTimeout(mcpTimeout);
      const json = await resp.json() as any;
      const textContent = json?.result?.content?.find((c: any) => c.type === 'text');
      content = textContent?.text ?? '';
    }

    this.writeEvent(httpRes, AgUiEventType.STEP_FINISHED, { stepName: 'aicore_stream', runId, threadId });

    // Wrap response via SchemaGenerator
    const intentWithContext = content
      ? `${userMessage}\n\nAssistant context (from AI Core streaming):\n${content}`
      : userMessage;
    const result = await this.schemaGenerator.generateSchema(
      {
        userIntent: intentWithContext,
        context: { availableData: session.state, previousUI: session.currentSchema },
      },
      this.llmPlugin as any
    );
    return result.schema;
  }

  // ---------------------------------------------------------------------------
  // Fallback: direct OrchestrationClient schema generation
  // ---------------------------------------------------------------------------

  private async generateSchemaDirectly(userMessage: string, session: AgentSession): Promise<A2UiSchema> {
    const result = await this.schemaGenerator.generateSchema(
      { userIntent: userMessage, context: { availableData: session.state, previousUI: session.currentSchema } },
      this.llmPlugin as any
    );
    return result.schema;
  }

  private writeEvent(httpRes: ServerResponse, type: AgUiEventType, data: Record<string, unknown>): void {
    const event = { type, timestamp: Date.now(), ...data };
    try {
      httpRes.write(serializeEvent(event as any));
    } catch { /* connection closed */ }
  }

  private generateId(prefix: string): string {
    const id = typeof crypto !== "undefined" && crypto.randomUUID
      ? crypto.randomUUID().replace(/-/g, "").slice(0, 12)
      : Math.random().toString(36).substr(2, 12);
    return `${prefix}-${Date.now()}-${id}`;
  }
}

// =============================================================================
// CDS Service Factory
// =============================================================================

export function createAgUiServiceHandler(config: AgUiAgentConfig) {
  return class AgUiService extends (cds as any).Service {
    agent!: AgUiAgentService;

    async init(): Promise<void> {
      await super.init();
      const llmPlugin = await cds.connect.to('cap-llm-plugin');
      this.agent = new AgUiAgentService(config, llmPlugin);
      LOG.info('AG-UI Agent Service initialized');
    }

    async run(req: any): Promise<void> {
      const httpRes = req.http?.res;
      if (!httpRes) throw new Error('HTTP response not available');
      await this.agent.handleRunRequest(req.data, httpRes);
    }

    async toolResult(req: any): Promise<{ success: boolean }> {
      await this.agent.handleToolResult(req.data);
      return { success: true };
    }

    async getSession(req: any): Promise<AgentSession | null> {
      return this.agent.getSession(req.data.threadId) ?? null;
    }

    async clearSession(req: any): Promise<{ success: boolean }> {
      this.agent.clearSession(req.data.threadId);
      return { success: true };
    }

    async health(): Promise<{ status: string; service: string; activeSessions: number; timestamp: number }> {
      return this.agent.health();
    }

    getAgent(): AgUiAgentService {
      return this.agent;
    }
  };
}