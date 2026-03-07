"use strict";
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
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.AgUiAgentService = void 0;
exports.createAgUiServiceHandler = createAgUiServiceHandler;
const cds = __importStar(require("@sap/cds"));
const event_types_1 = require("./event-types");
const schema_generator_1 = require("./schema-generator");
const tool_handler_1 = require("./tool-handler");
const tracer_1 = require("../../src/telemetry/tracer");
const intent_router_1 = require("./intent-router");
const pal_client_1 = require("./pal-client");
const LOG = cds.log('ag-ui-agent');
// =============================================================================
// AG-UI Agent Service
// =============================================================================
class AgUiAgentService {
    constructor(config, llmPlugin) {
        this.sessions = new Map();
        this.config = config;
        this.llmPlugin = llmPlugin;
        this.schemaGenerator = new schema_generator_1.SchemaGenerator({
            modelName: config.uiModelName ?? config.chatModelName,
            resourceGroup: config.resourceGroup,
        });
        this.toolHandler = new tool_handler_1.ToolHandler();
        this.intentRouter = new intent_router_1.IntentRouter({
            vllmEndpoint: config.vllmEndpoint,
            palEndpoint: config.palEndpoint,
            mcpEndpoint: config.mcpEndpoint,
            confidentialKeywords: config.confidentialKeywords,
            palKeywords: config.palKeywords,
        });
        this.palClient = new pal_client_1.PalClient(config.palEndpoint ?? 'http://localhost:8084/mcp');
    }
    getToolRegistry() {
        return this.toolHandler.getRegistry();
    }
    async handleRunRequest(request, httpRes) {
        const span = (0, tracer_1.getTracer)().startSpan('ag-ui-agent.handleRunRequest');
        const threadId = request.threadId ?? this.generateId('thread');
        const runId = request.runId ?? this.generateId('run');
        httpRes.setHeader('Content-Type', 'text/event-stream');
        httpRes.setHeader('Cache-Control', 'no-cache');
        httpRes.setHeader('X-Accel-Buffering', 'no');
        httpRes.setHeader('Connection', 'keep-alive');
        httpRes.flushHeaders();
        try {
            let session = this.sessions.get(threadId);
            if (!session) {
                session = { threadId, runId, messages: [], state: {}, createdAt: Date.now(), lastActivityAt: Date.now() };
                this.sessions.set(threadId, session);
            }
            session.runId = runId;
            session.lastActivityAt = Date.now();
            for (const msg of request.messages) {
                session.messages.push({ role: msg.role, content: msg.content });
            }
            const userMessage = request.messages.find(m => m.role === 'user')?.content ?? '';
            // Routing decision
            const forceBackend = request.forceBackend;
            const route = this.intentRouter.classify(userMessage, {
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
                this.writeEvent(httpRes, event_types_1.AgUiEventType.RUN_ERROR, {
                    runId, message: `Request blocked: ${route.reason}`, code: 'REQUEST_BLOCKED',
                });
                httpRes.write((0, event_types_1.createErrorFrame)('REQUEST_BLOCKED', route.reason));
                httpRes.end();
                span.setStatus({ code: tracer_1.SpanStatusCode.ERROR, message: route.reason });
                span.end();
                return;
            }
            // RUN_STARTED
            this.writeEvent(httpRes, event_types_1.AgUiEventType.RUN_STARTED, { runId, threadId });
            // Loading UI
            this.writeEvent(httpRes, event_types_1.AgUiEventType.CUSTOM, {
                name: event_types_1.GenUiEventNames.UI_SCHEMA_SNAPSHOT,
                value: (0, schema_generator_1.createLoadingSchema)('Generating UI...'),
                runId, threadId,
            });
            this.writeEvent(httpRes, event_types_1.AgUiEventType.STEP_STARTED, { stepName: 'generate_ui', runId, threadId });
            let schema;
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
            this.writeEvent(httpRes, event_types_1.AgUiEventType.STEP_FINISHED, { stepName: 'generate_ui', runId, threadId });
            this.writeEvent(httpRes, event_types_1.AgUiEventType.CUSTOM, {
                name: event_types_1.GenUiEventNames.UI_SCHEMA_SNAPSHOT,
                value: schema,
                runId, threadId,
            });
            this.writeEvent(httpRes, event_types_1.AgUiEventType.RUN_FINISHED, { runId, threadId });
            httpRes.write((0, event_types_1.createDoneSentinel)());
            span.setStatus({ code: tracer_1.SpanStatusCode.OK });
        }
        catch (e) {
            const error = e;
            LOG.error('AG-UI run failed:', error);
            span.recordException(error);
            this.writeEvent(httpRes, event_types_1.AgUiEventType.RUN_ERROR, { runId, message: error.message, code: 'AGENT_ERROR' });
            this.writeEvent(httpRes, event_types_1.AgUiEventType.CUSTOM, {
                name: event_types_1.GenUiEventNames.UI_SCHEMA_SNAPSHOT,
                value: (0, schema_generator_1.createErrorSchema)(error.message),
                runId, threadId: request.threadId ?? 'unknown',
            });
            httpRes.write((0, event_types_1.createErrorFrame)('AGENT_ERROR', error.message));
        }
        finally {
            httpRes.end();
            span.end();
        }
    }
    async handleToolResult(request) {
        await this.toolHandler.processToolResult(request);
    }
    async streamTextResponse(messages, httpRes, threadId, runId) {
        httpRes.setHeader('Content-Type', 'text/event-stream');
        httpRes.setHeader('Cache-Control', 'no-cache');
        httpRes.setHeader('Connection', 'keep-alive');
        httpRes.flushHeaders();
        const messageId = this.generateId('msg');
        try {
            this.writeEvent(httpRes, event_types_1.AgUiEventType.TEXT_MESSAGE_START, { messageId, role: 'assistant', runId, threadId });
            const response = await this.llmPlugin.getChatCompletionWithConfig({ modelName: this.config.chatModelName, resourceGroup: this.config.resourceGroup }, { messages });
            const content = response?.getContent?.() ?? String(response);
            const chunkSize = 50;
            for (let i = 0; i < content.length; i += chunkSize) {
                this.writeEvent(httpRes, event_types_1.AgUiEventType.TEXT_MESSAGE_CONTENT, {
                    messageId, delta: content.substring(i, i + chunkSize), runId, threadId,
                });
            }
            this.writeEvent(httpRes, event_types_1.AgUiEventType.TEXT_MESSAGE_END, { messageId, runId, threadId });
        }
        catch (e) {
            httpRes.write((0, event_types_1.createErrorFrame)('STREAM_ERROR', e.message));
        }
        finally {
            httpRes.write((0, event_types_1.createDoneSentinel)());
            httpRes.end();
        }
    }
    getSession(threadId) {
        return this.sessions.get(threadId);
    }
    clearSession(threadId) {
        this.sessions.delete(threadId);
    }
    // ---------------------------------------------------------------------------
    // Route B: vLLM (confidential data)
    // Uses @sap-ai-sdk/vllm VllmChatClient when available, falls back to fetch
    // ---------------------------------------------------------------------------
    async generateSchemaViaVllm(userMessage, session, httpRes, runId, threadId) {
        const vllmEndpoint = this.config.vllmEndpoint ?? 'http://localhost:9180';
        const model = this.config.vllmModel ?? 'Qwen/Qwen3.5-35B';
        this.writeEvent(httpRes, event_types_1.AgUiEventType.STEP_STARTED, { stepName: 'vllm_chat', runId, threadId });
        let vllmClient;
        try {
            const { VllmChatClient } = await Promise.resolve(`${'@sap-ai-sdk/vllm'}`).then(s => __importStar(require(s)));
            vllmClient = new VllmChatClient({ endpoint: vllmEndpoint, model });
        }
        catch {
            vllmClient = null;
        }
        let content;
        if (vllmClient) {
            const messages = [
                { role: 'system', content: 'You are a helpful assistant for confidential data processing.' },
                ...session.messages.slice(-6),
                { role: 'user', content: userMessage },
            ];
            const response = await vllmClient.chat(messages, { maxTokens: 2048, temperature: 0.7 });
            content = response?.choices?.[0]?.message?.content ?? '';
        }
        else {
            // Fallback: raw HTTP to vLLM OpenAI-compat endpoint
            const resp = await fetch(`${vllmEndpoint}/v1/chat/completions`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
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
            const json = await resp.json();
            content = json?.choices?.[0]?.message?.content ?? '';
        }
        this.writeEvent(httpRes, event_types_1.AgUiEventType.STEP_FINISHED, { stepName: 'vllm_chat', runId, threadId });
        // Generate UI schema via SchemaGenerator using the vLLM response as context
        const intentWithContext = content
            ? `${userMessage}\n\nAssistant context (from on-premise model):\n${content}`
            : userMessage;
        const result = await this.schemaGenerator.generateSchema({
            userIntent: intentWithContext,
            context: { availableData: session.state, previousUI: session.currentSchema },
        }, this.llmPlugin);
        return result.schema;
    }
    // ---------------------------------------------------------------------------
    // Route C: PAL analytics (ai-core-pal MCP)
    // ---------------------------------------------------------------------------
    async generateSchemaViaPal(userMessage, session, httpRes, runId, threadId) {
        this.writeEvent(httpRes, event_types_1.AgUiEventType.STEP_STARTED, { stepName: 'pal_search', runId, threadId });
        const palTable = session.state['hanaTable'];
        const schema = await this.palClient.generatePalTableSchema(userMessage, palTable);
        this.writeEvent(httpRes, event_types_1.AgUiEventType.STEP_FINISHED, { stepName: 'pal_search', runId, threadId });
        return schema;
    }
    // ---------------------------------------------------------------------------
    // Route D: HANA RAG (HANAVectorStore + OrchestrationClient)
    // ---------------------------------------------------------------------------
    async generateSchemaWithRag(userMessage, session, httpRes, runId, threadId) {
        const plugin = this.llmPlugin;
        this.writeEvent(httpRes, event_types_1.AgUiEventType.STEP_STARTED, { stepName: 'generate_embedding', runId, threadId });
        const embeddingResponse = await plugin.getEmbeddingWithConfig({ modelName: this.config.embeddingModelName ?? 'text-embedding-ada-002', resourceGroup: this.config.resourceGroup }, userMessage);
        const embedding = embeddingResponse.getEmbeddings()[0].embedding;
        this.writeEvent(httpRes, event_types_1.AgUiEventType.STEP_FINISHED, { stepName: 'generate_embedding', runId, threadId });
        this.writeEvent(httpRes, event_types_1.AgUiEventType.STEP_STARTED, { stepName: 'similarity_search', runId, threadId });
        const similarDocs = await plugin.similaritySearch(this.config.ragTable, this.config.ragEmbeddingColumn, this.config.ragContentColumn, embedding, 'COSINE_SIMILARITY', 3);
        this.writeEvent(httpRes, event_types_1.AgUiEventType.STEP_FINISHED, { stepName: 'similarity_search', runId, threadId });
        const context = similarDocs?.map((d) => d.PAGE_CONTENT).join('\n\n') ?? '';
        const result = await this.schemaGenerator.generateSchema({ userIntent: `${userMessage}\n\nContext from knowledge base:\n${context}`, context: { availableData: session.state } }, plugin);
        return result.schema;
    }
    // ---------------------------------------------------------------------------
    // Route E: ai-core-streaming MCP (default: public/internal)
    // Calls stream_complete tool via MCP JSON-RPC
    // ---------------------------------------------------------------------------
    async generateSchemaViaAicoreStreaming(userMessage, session, httpRes, runId, threadId) {
        const mcpEndpoint = this.config.mcpEndpoint ?? 'http://localhost:9190/mcp';
        this.writeEvent(httpRes, event_types_1.AgUiEventType.STEP_STARTED, { stepName: 'aicore_stream', runId, threadId });
        let mcpClient;
        try {
            const { AISdkMcpClient } = await Promise.resolve(`${'@sap-ai-sdk/mcp-server'}`).then(s => __importStar(require(s)));
            mcpClient = new AISdkMcpClient({ endpoint: mcpEndpoint });
        }
        catch {
            mcpClient = null;
        }
        let content;
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
        }
        else {
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
            const resp = await fetch(mcpEndpoint, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body),
            });
            const json = await resp.json();
            const textContent = json?.result?.content?.find((c) => c.type === 'text');
            content = textContent?.text ?? '';
        }
        this.writeEvent(httpRes, event_types_1.AgUiEventType.STEP_FINISHED, { stepName: 'aicore_stream', runId, threadId });
        // Wrap response via SchemaGenerator
        const intentWithContext = content
            ? `${userMessage}\n\nAssistant context (from AI Core streaming):\n${content}`
            : userMessage;
        const result = await this.schemaGenerator.generateSchema({
            userIntent: intentWithContext,
            context: { availableData: session.state, previousUI: session.currentSchema },
        }, this.llmPlugin);
        return result.schema;
    }
    // ---------------------------------------------------------------------------
    // Fallback: direct OrchestrationClient schema generation
    // ---------------------------------------------------------------------------
    async generateSchemaDirectly(userMessage, session) {
        const result = await this.schemaGenerator.generateSchema({ userIntent: userMessage, context: { availableData: session.state, previousUI: session.currentSchema } }, this.llmPlugin);
        return result.schema;
    }
    writeEvent(httpRes, type, data) {
        const event = { type, timestamp: Date.now(), ...data };
        try {
            httpRes.write((0, event_types_1.serializeEvent)(event));
        }
        catch { /* connection closed */ }
    }
    generateId(prefix) {
        return `${prefix}-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
    }
}
exports.AgUiAgentService = AgUiAgentService;
// =============================================================================
// CDS Service Factory
// =============================================================================
function createAgUiServiceHandler(config) {
    return class AgUiService extends cds.Service {
        async init() {
            await super.init();
            const llmPlugin = await cds.connect.to('cap-llm-plugin');
            this.agent = new AgUiAgentService(config, llmPlugin);
            LOG.info('AG-UI Agent Service initialized');
        }
        async run(req) {
            const httpRes = req.http?.res;
            if (!httpRes)
                throw new Error('HTTP response not available');
            await this.agent.handleRunRequest(req.data, httpRes);
        }
        async toolResult(req) {
            await this.agent.handleToolResult(req.data);
            return { success: true };
        }
        async getSession(req) {
            return this.agent.getSession(req.data.threadId) ?? null;
        }
        async clearSession(req) {
            this.agent.clearSession(req.data.threadId);
            return { success: true };
        }
        getAgent() {
            return this.agent;
        }
    };
}
//# sourceMappingURL=agent-service.js.map