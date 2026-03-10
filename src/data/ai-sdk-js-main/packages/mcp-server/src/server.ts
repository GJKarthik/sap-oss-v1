// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SAP AI SDK MCP Server
 * 
 * Model Context Protocol server with Mangle reasoning integration.
 * Provides tools, resources, and prompts for SAP AI Core operations.
 */

import * as http from 'http';
import * as https from 'https';
import { URL } from 'url';
import { WebSocketServer, WebSocket } from 'ws';
import { v4 as uuid } from 'uuid';

let _getKuzuStore: (() => import('./kuzu-store').KuzuStore) | null = null;
try {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const kuzuMod = require('./kuzu-store');
  _getKuzuStore = kuzuMod.getKuzuStore as () => import('./kuzu-store').KuzuStore;
} catch {
  _getKuzuStore = null;
}
const REMOTE_MCP_TIMEOUT_MS = 2500;

// =============================================================================
// Types
// =============================================================================

interface MCPRequest {
  jsonrpc: '2.0';
  id: string | number;
  method: string;
  params?: Record<string, unknown>;
}

interface MCPResponse {
  jsonrpc: '2.0';
  id: string | number;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

interface MCPNotification {
  jsonrpc: '2.0';
  method: string;
  params?: Record<string, unknown>;
}

interface Tool {
  name: string;
  description: string;
  inputSchema: {
    type: 'object';
    properties: Record<string, { type: string; description: string }>;
    required?: string[];
  };
}

interface Resource {
  uri: string;
  name: string;
  description: string;
  mimeType: string;
}

interface Prompt {
  name: string;
  description: string;
  arguments?: Array<{ name: string; description: string; required?: boolean }>;
}

// =============================================================================
// AI Core Configuration
// =============================================================================

interface AICoreConfig {
  clientId: string;
  clientSecret: string;
  authUrl: string;
  baseUrl: string;
  resourceGroup: string;
}

function safeJsonParse<T>(value: unknown, fallback: T): T {
  if (typeof value !== 'string') return fallback;
  try {
    return JSON.parse(value) as T;
  } catch {
    return fallback;
  }
}

function normalizeMcpEndpoint(endpoint: string): string {
  const trimmed = endpoint.trim().replace(/\/+$/, '');
  return trimmed.endsWith('/mcp') ? trimmed : `${trimmed}/mcp`;
}

function getRemoteMcpEndpoints(envKey: string): string[] {
  const raw = process.env[envKey] || '';
  return raw
    .split(',')
    .map(v => v.trim())
    .filter(Boolean)
    .map(normalizeMcpEndpoint);
}

function unwrapMcpToolResult(result: unknown): unknown {
  if (!result || typeof result !== 'object') return result;
  const content = (result as { content?: unknown }).content;
  if (!Array.isArray(content) || content.length === 0) return result;
  const first = content[0];
  if (!first || typeof first !== 'object') return result;
  const text = (first as { text?: unknown }).text;
  if (typeof text !== 'string') return result;
  return safeJsonParse<unknown>(text, text);
}

async function callMcpTool(
  endpoint: string,
  toolName: string,
  toolArgs: Record<string, unknown>,
  timeoutMs: number = REMOTE_MCP_TIMEOUT_MS,
): Promise<unknown> {
  const target = new URL(endpoint);
  const body = JSON.stringify({
    jsonrpc: '2.0',
    id: 1,
    method: 'tools/call',
    params: {
      name: toolName,
      arguments: toolArgs,
    },
  });
  const client = target.protocol === 'http:' ? http : https;

  return new Promise((resolve, reject) => {
    const req = client.request({
      hostname: target.hostname,
      port: target.port || (target.protocol === 'http:' ? 80 : 443),
      path: `${target.pathname}${target.search}`,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
    }, (res) => {
      let data = '';
      res.on('data', (chunk: string) => data += chunk);
      res.on('end', () => {
        try {
          const rpc = JSON.parse(data) as { result?: unknown; error?: { message?: string } };
          if (rpc.error) {
            return reject(new Error(rpc.error.message || 'remote MCP error'));
          }
          resolve(unwrapMcpToolResult(rpc.result));
        } catch (err) {
          reject(err);
        }
      });
    });
    req.setTimeout(timeoutMs, () => req.destroy(new Error(`remote MCP timeout after ${timeoutMs}ms`)));
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

function getConfig(): AICoreConfig {
  return {
    clientId: process.env.AICORE_CLIENT_ID || '',
    clientSecret: process.env.AICORE_CLIENT_SECRET || '',
    authUrl: process.env.AICORE_AUTH_URL || '',
    baseUrl: process.env.AICORE_BASE_URL || process.env.AICORE_SERVICE_URL || '',
    resourceGroup: process.env.AICORE_RESOURCE_GROUP || 'default',
  };
}

// Token cache
let cachedToken: { token: string | null; expiresAt: number } = { token: null, expiresAt: 0 };

async function getAccessToken(config: AICoreConfig): Promise<string> {
  if (cachedToken.token && Date.now() < cachedToken.expiresAt) {
    return cachedToken.token;
  }

  const auth = Buffer.from(`${config.clientId}:${config.clientSecret}`).toString('base64');
  
  return new Promise((resolve, reject) => {
    const url = new URL(config.authUrl);
    const req = https.request({
      hostname: url.hostname,
      port: 443,
      path: url.pathname,
      method: 'POST',
      headers: { 'Authorization': `Basic ${auth}`, 'Content-Type': 'application/x-www-form-urlencoded' },
    }, (res) => {
      let data = '';
      res.on('data', (chunk: string) => data += chunk);
      res.on('end', () => {
        try {
          const result = JSON.parse(data);
          cachedToken = { token: result.access_token, expiresAt: Date.now() + (result.expires_in - 60) * 1000 };
          resolve(result.access_token);
        } catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.write('grant_type=client_credentials');
    req.end();
  });
}

async function aicoreRequest(config: AICoreConfig, method: string, path: string, body?: unknown): Promise<unknown> {
  const token = await getAccessToken(config);
  const url = new URL(path, config.baseUrl);
  
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: url.hostname,
      port: 443,
      path: url.pathname + url.search,
      method,
      headers: {
        'Authorization': `Bearer ${token}`,
        'AI-Resource-Group': config.resourceGroup,
        'Content-Type': 'application/json',
      },
    }, (res) => {
      let data = '';
      res.on('data', (chunk: string) => data += chunk);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); } catch { resolve(data); }
      });
    });
    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

// =============================================================================
// MCP Server Implementation
// =============================================================================

class MCPServer {
  private tools: Map<string, Tool> = new Map();
  private resources: Map<string, Resource> = new Map();
  private prompts: Map<string, Prompt> = new Map();
  private toolHandlers: Map<string, (args: Record<string, unknown>) => Promise<unknown>> = new Map();
  private facts: Map<string, unknown[]> = new Map(); // Mangle fact store
  
  constructor() {
    this.registerTools();
    this.registerResources();
    this.registerPrompts();
    this.initializeFacts();
  }

  // ===========================================================================
  // Tool Registration
  // ===========================================================================

  private registerTools(): void {
    // Chat Completion Tool
    this.tools.set('ai_core_chat', {
      name: 'ai_core_chat',
      description: 'Send a chat completion request to SAP AI Core (Claude, GPT-4, etc.)',
      inputSchema: {
        type: 'object',
        properties: {
          model: { type: 'string', description: 'Model ID or deployment ID' },
          messages: { type: 'string', description: 'JSON array of messages [{role, content}]' },
          max_tokens: { type: 'number', description: 'Maximum tokens to generate' },
          temperature: { type: 'number', description: 'Temperature (0-1)' },
        },
        required: ['messages'],
      },
    });
    this.toolHandlers.set('ai_core_chat', this.handleChatTool.bind(this));

    // Embedding Tool
    this.tools.set('ai_core_embed', {
      name: 'ai_core_embed',
      description: 'Generate embeddings using SAP AI Core',
      inputSchema: {
        type: 'object',
        properties: {
          input: { type: 'string', description: 'Text to embed (or JSON array of texts)' },
          model: { type: 'string', description: 'Embedding model ID' },
        },
        required: ['input'],
      },
    });
    this.toolHandlers.set('ai_core_embed', this.handleEmbedTool.bind(this));

    // HANA Vector Search Tool
    this.tools.set('hana_vector_search', {
      name: 'hana_vector_search',
      description: 'Search HANA Cloud vector store for similar documents',
      inputSchema: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'Search query text' },
          table_name: { type: 'string', description: 'Vector table name' },
          top_k: { type: 'number', description: 'Number of results to return' },
        },
        required: ['query', 'table_name'],
      },
    });
    this.toolHandlers.set('hana_vector_search', this.handleVectorSearchTool.bind(this));

    // List Deployments Tool
    this.tools.set('list_deployments', {
      name: 'list_deployments',
      description: 'List all AI Core deployments',
      inputSchema: {
        type: 'object',
        properties: {},
      },
    });
    this.toolHandlers.set('list_deployments', this.handleListDeploymentsTool.bind(this));

    // Orchestration Tool
    this.tools.set('orchestration_run', {
      name: 'orchestration_run',
      description: 'Run an orchestration scenario with multiple models',
      inputSchema: {
        type: 'object',
        properties: {
          scenario: { type: 'string', description: 'Orchestration scenario name' },
          input: { type: 'string', description: 'Input data as JSON' },
        },
        required: ['scenario', 'input'],
      },
    });
    this.toolHandlers.set('orchestration_run', this.handleOrchestrationTool.bind(this));

    // Mangle Query Tool
    this.tools.set('mangle_query', {
      name: 'mangle_query',
      description: 'Query the Mangle reasoning engine',
      inputSchema: {
        type: 'object',
        properties: {
          predicate: { type: 'string', description: 'Predicate to query (e.g., "deployment_ready")' },
          args: { type: 'string', description: 'Arguments as JSON array' },
        },
        required: ['predicate'],
      },
    });
    this.toolHandlers.set('mangle_query', this.handleMangleQueryTool.bind(this));

    // Graph-RAG: index AI SDK entities into KùzuDB
    this.tools.set('kuzu_index', {
      name: 'kuzu_index',
      description:
        'Index SAP AI SDK entities into the embedded KùzuDB graph database. ' +
        'Stores AiDeployment nodes, AiModel nodes, OrchestrationScenario nodes, and their ' +
        'relationships (USES_MODEL, RUNS_SCENARIO, ROUTES_TO). ' +
        'Call before list_deployments to enable graph-context enrichment.',
      inputSchema: {
        type: 'object',
        properties: {
          deployments: {
            type: 'string',
            description:
              'JSON array of deployment definitions: ' +
              '[{deploymentId, modelName?, resourceGroup?, status?, usesModel?: string, runsScenario?: string}]',
          },
          models: {
            type: 'string',
            description:
              'JSON array of model definitions: ' +
              '[{modelId, modelFamily?, provider?, capabilities?}]',
          },
          scenarios: {
            type: 'string',
            description:
              'JSON array of scenario definitions: ' +
              '[{scenarioId, name?, description?, dataClass?, routesTo?: string}]',
          },
        },
      },
    });
    this.toolHandlers.set('kuzu_index', this.handleKuzuIndexTool.bind(this));

    // Graph-RAG: run a read-only Cypher query against KùzuDB
    this.tools.set('kuzu_query', {
      name: 'kuzu_query',
      description:
        'Execute a read-only Cypher query against the embedded KùzuDB graph database ' +
        'and return matching rows as JSON. ' +
        'Use for deployment lookup, model graph traversal, scenario analysis.',
      inputSchema: {
        type: 'object',
        properties: {
          cypher: {
            type: 'string',
            description: 'Cypher query string (MATCH … RETURN only)',
          },
          params: {
            type: 'string',
            description: 'Query parameters as JSON object (optional)',
          },
        },
        required: ['cypher'],
      },
    });
    this.toolHandlers.set('kuzu_query', this.handleKuzuQueryTool.bind(this));
  }

  // ===========================================================================
  // Resource Registration
  // ===========================================================================

  private registerResources(): void {
    this.resources.set('deployment://list', {
      uri: 'deployment://list',
      name: 'AI Core Deployments',
      description: 'List of all AI Core deployments',
      mimeType: 'application/json',
    });

    this.resources.set('model://info', {
      uri: 'model://info',
      name: 'Model Information',
      description: 'Information about available models',
      mimeType: 'application/json',
    });

    this.resources.set('mangle://facts', {
      uri: 'mangle://facts',
      name: 'Mangle Facts',
      description: 'Current facts in the Mangle reasoning engine',
      mimeType: 'application/json',
    });

    this.resources.set('mangle://rules', {
      uri: 'mangle://rules',
      name: 'Mangle Rules',
      description: 'Defined Mangle reasoning rules',
      mimeType: 'text/plain',
    });
  }

  // ===========================================================================
  // Prompt Registration
  // ===========================================================================

  private registerPrompts(): void {
    this.prompts.set('rag_query', {
      name: 'rag_query',
      description: 'RAG query prompt for vector search + generation',
      arguments: [
        { name: 'query', description: 'User query', required: true },
        { name: 'context_size', description: 'Number of context documents', required: false },
      ],
    });

    this.prompts.set('data_analysis', {
      name: 'data_analysis',
      description: 'Prompt for analyzing data patterns',
      arguments: [
        { name: 'data_description', description: 'Description of the data', required: true },
        { name: 'analysis_type', description: 'Type of analysis (statistical, trend, anomaly)', required: false },
      ],
    });
  }

  // ===========================================================================
  // Mangle Facts Initialization
  // ===========================================================================

  private initializeFacts(): void {
    const localPort = Number.parseInt(process.env.MCP_PORT || '9090', 10) || 9090;
    const serviceRegistry: Array<Record<string, unknown>> = [
      { name: 'sap-ai-sdk-mcp', endpoint: `http://localhost:${localPort}/mcp`, model: 'sap-ai-sdk-mcp' },
      { name: 'ai-core-chat', endpoint: 'aicore://chat', model: 'claude-3.5-sonnet' },
      { name: 'ai-core-embed', endpoint: 'aicore://embed', model: 'text-embedding-ada-002' },
      { name: 'hana-vector', endpoint: 'hana://vector', model: 'vector-store' },
    ];
    getRemoteMcpEndpoints('AI_SDK_REMOTE_MCP_ENDPOINTS').forEach((endpoint, index) => {
      serviceRegistry.push({ name: `remote-mcp-${index + 1}`, endpoint, model: 'federated' });
    });

    // Service registry facts
    this.facts.set('service_registry', serviceRegistry);

    // Deployment facts (populated dynamically)
    this.facts.set('deployment', []);

    // Tool invocation facts (audit log)
    this.facts.set('tool_invocation', []);
  }

  private getFederatedMcpEndpoints(): string[] {
    const endpoints = new Set<string>();

    getRemoteMcpEndpoints('AI_SDK_REMOTE_MCP_ENDPOINTS').forEach(endpoint => endpoints.add(endpoint));

    const orchestrationEndpoint = process.env.AI_SDK_ORCHESTRATION_MCP_ENDPOINT;
    if (orchestrationEndpoint && orchestrationEndpoint.trim() !== '') {
      endpoints.add(normalizeMcpEndpoint(orchestrationEndpoint));
    }

    const services = this.facts.get('service_registry');
    if (Array.isArray(services)) {
      services.forEach((service) => {
        if (!service || typeof service !== 'object') return;
        const endpoint = (service as { endpoint?: unknown }).endpoint;
        if (typeof endpoint === 'string' && /^https?:\/\//.test(endpoint)) {
          endpoints.add(normalizeMcpEndpoint(endpoint));
        }
      });
    }

    return Array.from(endpoints);
  }

  // ===========================================================================
  // Tool Handlers
  // ===========================================================================

  private async handleChatTool(args: Record<string, unknown>): Promise<unknown> {
    const config = getConfig();
    const messages = typeof args.messages === 'string' ? JSON.parse(args.messages as string) : args.messages;
    
    // Get deployments
    const deploymentsResult = await aicoreRequest(config, 'GET', '/v2/lm/deployments') as { resources?: Array<{ id: string; details?: { resources?: { backend_details?: { model?: { name?: string } } } } }> };
    const deployments = deploymentsResult.resources || [];
    
    // Find deployment
    const modelId = args.model as string || 'claude';
    const deployment = deployments.find(d => 
      d.id === modelId || 
      d.details?.resources?.backend_details?.model?.name?.toLowerCase().includes(modelId.toLowerCase())
    ) || deployments[0];
    
    if (!deployment) {
      return { error: 'No deployment available' };
    }

    const isAnthropic = deployment.details?.resources?.backend_details?.model?.name?.toLowerCase().includes('anthropic');

    // Log tool invocation as Mangle fact
    this.facts.get('tool_invocation')?.push({
      tool: 'ai_core_chat',
      deployment: deployment.id,
      timestamp: Date.now(),
    });

    if (isAnthropic) {
      const result = await aicoreRequest(config, 'POST', `/v2/inference/deployments/${deployment.id}/invoke`, {
        anthropic_version: 'bedrock-2023-05-31',
        max_tokens: args.max_tokens || 1024,
        messages,
      }) as { content?: Array<{ text?: string }> };
      
      return { content: result.content?.[0]?.text || '', model: deployment.id };
    } else {
      const result = await aicoreRequest(config, 'POST', `/v2/inference/deployments/${deployment.id}/chat/completions`, {
        messages,
        max_tokens: args.max_tokens,
        temperature: args.temperature,
      });
      return result;
    }
  }

  private async handleEmbedTool(args: Record<string, unknown>): Promise<unknown> {
    const config = getConfig();
    const input = typeof args.input === 'string' ? 
      (args.input.startsWith('[') ? JSON.parse(args.input as string) : [args.input]) : 
      [args.input];
    
    const deploymentsResult = await aicoreRequest(config, 'GET', '/v2/lm/deployments') as { resources?: Array<{ id: string; details?: { resources?: { backend_details?: { model?: { name?: string } } } } }> };
    const deployments = deploymentsResult.resources || [];
    const deployment = deployments.find(d => 
      d.details?.resources?.backend_details?.model?.name?.toLowerCase().includes('embed')
    ) || deployments[0];
    
    if (!deployment) {
      return { error: 'No embedding deployment available' };
    }

    const result = await aicoreRequest(config, 'POST', `/v2/inference/deployments/${deployment.id}/embeddings`, {
      input,
      model: args.model,
    });
    
    return result;
  }

  private async handleVectorSearchTool(args: Record<string, unknown>): Promise<unknown> {
    // This would integrate with HANA Cloud vector store
    // For now, return a placeholder
    return {
      results: [],
      query: args.query,
      table_name: args.table_name,
      message: 'Connect to HANA Cloud for actual vector search',
    };
  }

  private async handleListDeploymentsTool(_args: Record<string, unknown>): Promise<unknown> {
    const config = getConfig();
    const result = await aicoreRequest(config, 'GET', '/v2/lm/deployments') as { resources?: Array<Record<string, unknown>> };

    // Update Mangle facts
    this.facts.set('deployment', result.resources || []);

    // M4 — attach graph context when KùzuDB has indexed data
    if (_getKuzuStore) {
      const store = _getKuzuStore();
      if (store.available() && Array.isArray(result.resources)) {
        const enriched = await Promise.all(
          result.resources.map(async (dep) => {
            const depId = (dep['id'] ?? dep['deploymentId'] ?? '') as string;
            if (!depId) return dep;
            const ctx = await store.getDeploymentContext(depId);
            return ctx.length > 0 ? { ...dep, graphContext: ctx } : dep;
          }),
        );
        return { ...result, resources: enriched };
      }
    }

    return result;
  }

  private async handleOrchestrationTool(args: Record<string, unknown>): Promise<unknown> {
    // Orchestration scenarios
    const scenario = args.scenario as string;
    const input = typeof args.input === 'string' ? safeJsonParse<unknown>(args.input, args.input) : args.input;

    for (const endpoint of this.getFederatedMcpEndpoints()) {
      try {
        const remoteResult = await callMcpTool(endpoint, 'orchestration_run', { scenario, input });
        return {
          scenario,
          input,
          status: 'federated',
          source: endpoint,
          result: remoteResult,
        };
      } catch {
        // Try the next endpoint.
      }
    }

    return {
      scenario,
      input,
      status: 'Orchestration not yet implemented',
      message: 'Use orchestration package for full support',
    };
  }

  private async handleKuzuIndexTool(args: Record<string, unknown>): Promise<unknown> {
    if (!_getKuzuStore) {
      return { error: "KùzuDB not available; add \"kuzu\": \"^0.7.0\" to packages/mcp-server/package.json" };
    }
    const store = _getKuzuStore();
    if (!store.available()) {
      return { error: "KùzuDB not installed; add \"kuzu\": \"^0.7.0\" to packages/mcp-server/package.json" };
    }
    await store.ensureSchema();

    let deploymentsIndexed = 0;
    let modelsIndexed = 0;
    let scenariosIndexed = 0;

    // Index models first (referenced by deployments)
    const rawModels = safeJsonParse<unknown[]>(args['models'] as string ?? '[]', []);
    if (Array.isArray(rawModels)) {
      for (const m of rawModels) {
        if (!m || typeof m !== 'object') continue;
        const model = m as Record<string, unknown>;
        const modelId = String(model['modelId'] ?? '').trim();
        if (!modelId) continue;
        await store.upsertModel(
          modelId,
          String(model['modelFamily'] ?? ''),
          String(model['provider'] ?? ''),
          String(model['capabilities'] ?? ''),
        );
        modelsIndexed++;
      }
    }

    // Index scenarios
    const rawScenarios = safeJsonParse<unknown[]>(args['scenarios'] as string ?? '[]', []);
    if (Array.isArray(rawScenarios)) {
      for (const s of rawScenarios) {
        if (!s || typeof s !== 'object') continue;
        const scenario = s as Record<string, unknown>;
        const scenarioId = String(scenario['scenarioId'] ?? '').trim();
        if (!scenarioId) continue;
        await store.upsertScenario(
          scenarioId,
          String(scenario['name'] ?? ''),
          String(scenario['description'] ?? ''),
          String(scenario['dataClass'] ?? 'internal'),
        );
        scenariosIndexed++;
        const routesTo = String(scenario['routesTo'] ?? '').trim();
        if (routesTo) {
          await store.linkScenarioDeployment(scenarioId, routesTo);
        }
      }
    }

    // Index deployments
    const rawDeployments = safeJsonParse<unknown[]>(args['deployments'] as string ?? '[]', []);
    if (Array.isArray(rawDeployments)) {
      for (const d of rawDeployments) {
        if (!d || typeof d !== 'object') continue;
        const dep = d as Record<string, unknown>;
        const deploymentId = String(dep['deploymentId'] ?? '').trim();
        if (!deploymentId) continue;
        await store.upsertDeployment(
          deploymentId,
          String(dep['modelName'] ?? ''),
          String(dep['resourceGroup'] ?? 'default'),
          String(dep['status'] ?? 'unknown'),
        );
        deploymentsIndexed++;
        const usesModel = String(dep['usesModel'] ?? '').trim();
        if (usesModel) {
          await store.linkDeploymentModel(deploymentId, usesModel);
        }
        const runsScenario = String(dep['runsScenario'] ?? '').trim();
        if (runsScenario) {
          await store.linkDeploymentScenario(deploymentId, runsScenario);
        }
      }
    }

    return { deploymentsIndexed, modelsIndexed, scenariosIndexed };
  }

  private async handleKuzuQueryTool(args: Record<string, unknown>): Promise<unknown> {
    const cypher = String(args['cypher'] ?? '').trim();
    if (!cypher) {
      return { error: 'cypher is required' };
    }
    const upper = cypher.toUpperCase().trimStart();
    for (const disallowed of ['CREATE ', 'MERGE ', 'DELETE ', 'SET ', 'REMOVE ', 'DROP ']) {
      if (upper.startsWith(disallowed)) {
        return { error: 'Write Cypher statements are not permitted via this tool' };
      }
    }
    const params = safeJsonParse<Record<string, unknown>>(args['params'] as string ?? '{}', {});
    if (!_getKuzuStore) {
      return { error: "KùzuDB not available; add \"kuzu\": \"^0.7.0\" to packages/mcp-server/package.json" };
    }
    const store = _getKuzuStore();
    if (!store.available()) {
      return { error: "KùzuDB not installed; add \"kuzu\": \"^0.7.0\" to packages/mcp-server/package.json" };
    }
    const rows = await store.runQuery(cypher, typeof params === 'object' && params !== null ? params : {});
    return { rows, rowCount: rows.length };
  }

  private async handleMangleQueryTool(args: Record<string, unknown>): Promise<unknown> {
    const predicate = args.predicate as string;
    const queryArgs = Array.isArray(args.args) ? args.args : safeJsonParse<unknown[]>(args.args, []);
    
    // Simple fact lookup
    const facts = this.facts.get(predicate);
    if (facts) {
      return { predicate, results: facts };
    }

    // Derived predicates
    if (predicate === 'deployment_ready') {
      const deployments = this.facts.get('deployment') || [];
      const ready = (deployments as Array<{ status?: string }>).filter(d => d.status === 'RUNNING');
      return { predicate, results: ready };
    }

    if (predicate === 'service_available') {
      const services = this.facts.get('service_registry') || [];
      return { predicate, results: services };
    }

    for (const endpoint of this.getFederatedMcpEndpoints()) {
      try {
        const remoteResult = await callMcpTool(endpoint, 'mangle_query', {
          predicate,
          args: JSON.stringify(queryArgs),
        });
        if (remoteResult && typeof remoteResult === 'object') {
          const results = (remoteResult as { results?: unknown }).results;
          if (Array.isArray(results) && results.length > 0) {
            return { predicate, results, source: endpoint };
          }
        }
      } catch {
        // Try next endpoint.
      }
    }

    return { predicate, args: queryArgs, results: [], message: 'Unknown predicate' };
  }

  // ===========================================================================
  // MCP Protocol Handlers
  // ===========================================================================

  async handleRequest(request: MCPRequest): Promise<MCPResponse> {
    const { id, method, params } = request;

    try {
      switch (method) {
        case 'initialize':
          return this.handleInitialize(id, params);
        
        case 'tools/list':
          return this.handleToolsList(id);
        
        case 'tools/call':
          return await this.handleToolsCall(id, params);
        
        case 'resources/list':
          return this.handleResourcesList(id);
        
        case 'resources/read':
          return await this.handleResourcesRead(id, params);
        
        case 'prompts/list':
          return this.handlePromptsList(id);
        
        case 'prompts/get':
          return this.handlePromptsGet(id, params);
        
        default:
          return {
            jsonrpc: '2.0',
            id,
            error: { code: -32601, message: `Method not found: ${method}` },
          };
      }
    } catch (error) {
      return {
        jsonrpc: '2.0',
        id,
        error: { code: -32603, message: String(error) },
      };
    }
  }

  private handleInitialize(id: string | number, _params?: Record<string, unknown>): MCPResponse {
    return {
      jsonrpc: '2.0',
      id,
      result: {
        protocolVersion: '2024-11-05',
        capabilities: {
          tools: { listChanged: true },
          resources: { subscribe: false, listChanged: true },
          prompts: { listChanged: true },
        },
        serverInfo: {
          name: 'sap-ai-sdk-mcp',
          version: '1.0.0',
        },
      },
    };
  }

  private handleToolsList(id: string | number): MCPResponse {
    return {
      jsonrpc: '2.0',
      id,
      result: {
        tools: Array.from(this.tools.values()),
      },
    };
  }

  private async handleToolsCall(id: string | number, params?: Record<string, unknown>): Promise<MCPResponse> {
    const toolName = params?.name as string;
    const args = (params?.arguments || {}) as Record<string, unknown>;

    const handler = this.toolHandlers.get(toolName);
    if (!handler) {
      return {
        jsonrpc: '2.0',
        id,
        error: { code: -32602, message: `Unknown tool: ${toolName}` },
      };
    }

    const result = await handler(args);
    return {
      jsonrpc: '2.0',
      id,
      result: {
        content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
      },
    };
  }

  private handleResourcesList(id: string | number): MCPResponse {
    return {
      jsonrpc: '2.0',
      id,
      result: {
        resources: Array.from(this.resources.values()),
      },
    };
  }

  private async handleResourcesRead(id: string | number, params?: Record<string, unknown>): Promise<MCPResponse> {
    const uri = params?.uri as string;
    
    if (uri === 'deployment://list') {
      const config = getConfig();
      const result = await aicoreRequest(config, 'GET', '/v2/lm/deployments');
      return {
        jsonrpc: '2.0',
        id,
        result: {
          contents: [{ uri, mimeType: 'application/json', text: JSON.stringify(result, null, 2) }],
        },
      };
    }

    if (uri === 'mangle://facts') {
      const allFacts: Record<string, unknown> = {};
      this.facts.forEach((value, key) => { allFacts[key] = value; });
      return {
        jsonrpc: '2.0',
        id,
        result: {
          contents: [{ uri, mimeType: 'application/json', text: JSON.stringify(allFacts, null, 2) }],
        },
      };
    }

    if (uri === 'mangle://rules') {
      const rules = this.getMangleRules();
      return {
        jsonrpc: '2.0',
        id,
        result: {
          contents: [{ uri, mimeType: 'text/plain', text: rules }],
        },
      };
    }

    return {
      jsonrpc: '2.0',
      id,
      error: { code: -32602, message: `Unknown resource: ${uri}` },
    };
  }

  private handlePromptsList(id: string | number): MCPResponse {
    return {
      jsonrpc: '2.0',
      id,
      result: {
        prompts: Array.from(this.prompts.values()),
      },
    };
  }

  private handlePromptsGet(id: string | number, params?: Record<string, unknown>): MCPResponse {
    const promptName = params?.name as string;
    const prompt = this.prompts.get(promptName);
    
    if (!prompt) {
      return {
        jsonrpc: '2.0',
        id,
        error: { code: -32602, message: `Unknown prompt: ${promptName}` },
      };
    }

    // Generate prompt messages based on arguments
    const args = (params?.arguments || {}) as Record<string, string>;
    
    if (promptName === 'rag_query') {
      return {
        jsonrpc: '2.0',
        id,
        result: {
          messages: [
            { role: 'system', content: 'You are a helpful assistant that answers questions based on provided context.' },
            { role: 'user', content: `Query: ${args.query}\n\nPlease search for relevant context and provide a comprehensive answer.` },
          ],
        },
      };
    }

    if (promptName === 'data_analysis') {
      return {
        jsonrpc: '2.0',
        id,
        result: {
          messages: [
            { role: 'system', content: 'You are a data analyst expert.' },
            { role: 'user', content: `Analyze this data: ${args.data_description}\n\nAnalysis type: ${args.analysis_type || 'general'}` },
          ],
        },
      };
    }

    return {
      jsonrpc: '2.0',
      id,
      result: { messages: [] },
    };
  }

  private getMangleRules(): string {
    return `# SAP AI SDK Mangle Rules
# Service Registry
service_registry(Name, Endpoint, Model) :-
    facts.service_registry(Name, Endpoint, Model).

# Deployment Status
deployment_ready(DeploymentId) :-
    deployment(DeploymentId, _, "RUNNING", _).

# Service Available
service_available(Name) :-
    service_registry(Name, _, _).

# Tool Invocation Audit
recent_invocation(Tool, Deployment, Timestamp) :-
    tool_invocation(Tool, Deployment, Timestamp),
    Timestamp > now() - 3600000.

# Intent Routing
route_to_service(Intent, Service) :-
    Intent = "chat", Service = "ai-core-chat".
route_to_service(Intent, Service) :-
    Intent = "embed", Service = "ai-core-embed".
route_to_service(Intent, Service) :-
    Intent = "search", Service = "hana-vector".
`;
  }
}

// =============================================================================
// HTTP + WebSocket Server
// =============================================================================

const PORT = parseInt(process.env.MCP_PORT || process.argv.find(a => a.startsWith('--port='))?.split('=')[1] || '9090');

const mcpServer = new MCPServer();

// CORS: use CORS_ALLOWED_ORIGINS (comma-separated). Default allows localhost for dev.
const corsAllowedOrigins = (process.env.CORS_ALLOWED_ORIGINS ?? 'http://localhost:3000,http://127.0.0.1:3000')
  .split(',')
  .map((o) => o.trim())
  .filter(Boolean);

function getCorsOrigin(req: http.IncomingMessage): string | undefined {
  const origin = req.headers.origin;
  if (origin && corsAllowedOrigins.includes(origin)) return origin;
  return corsAllowedOrigins[0];
}

// HTTP Server for SSE transport
const httpServer = http.createServer(async (req, res) => {
  const corsOrigin = getCorsOrigin(req);
  if (corsOrigin) res.setHeader('Access-Control-Allow-Origin', corsOrigin);
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  const url = new URL(req.url || '/', `http://${req.headers.host}`);

  // Health check
  if (url.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'healthy', service: 'sap-ai-sdk-mcp-server', timestamp: new Date().toISOString() }));
    return;
  }

  // MCP JSON-RPC endpoint
  if (url.pathname === '/mcp' && req.method === 'POST') {
    let body = '';
    req.on('data', (chunk: string) => body += chunk);
    req.on('end', async () => {
      try {
        const request = JSON.parse(body) as MCPRequest;
        const response = await mcpServer.handleRequest(request);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(response));
      } catch (error) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }));
      }
    });
    return;
  }

  // SSE endpoint for streaming
  if (url.pathname === '/mcp/sse') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    });

    // Send initial connection event
    res.write(`data: ${JSON.stringify({ type: 'connected', server: 'sap-ai-sdk-mcp' })}\n\n`);

    // Keep connection alive
    const interval = setInterval(() => {
      res.write(`data: ${JSON.stringify({ type: 'ping', timestamp: Date.now() })}\n\n`);
    }, 30000);

    req.on('close', () => {
      clearInterval(interval);
    });
    return;
  }

  // 404
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

// WebSocket Server for stdio-over-websocket
const wss = new WebSocketServer({ server: httpServer, path: '/mcp/ws' });

wss.on('connection', (ws: WebSocket) => {
  console.log('MCP WebSocket client connected');

  ws.on('message', async (data: Buffer) => {
    try {
      const request = JSON.parse(data.toString()) as MCPRequest;
      const response = await mcpServer.handleRequest(request);
      ws.send(JSON.stringify(response));
    } catch (error) {
      ws.send(JSON.stringify({
        jsonrpc: '2.0',
        id: null,
        error: { code: -32700, message: 'Parse error' },
      }));
    }
  });

  ws.on('close', () => {
    console.log('MCP WebSocket client disconnected');
  });
});

if (require.main === module) {
httpServer.listen(PORT, () => {
  console.log(`
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║   SAP AI SDK MCP Server with Mangle Reasoning            ║
║   Model Context Protocol v2024-11-05                     ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝

Server running at: http://localhost:${PORT}

Transports:
  HTTP POST /mcp        - JSON-RPC over HTTP
  GET       /mcp/sse    - Server-Sent Events
  WebSocket /mcp/ws     - WebSocket transport

Tools:
  - ai_core_chat        - Chat completions via AI Core
  - ai_core_embed       - Embeddings via AI Core
  - hana_vector_search  - HANA vector similarity search
  - list_deployments    - List AI Core deployments
  - orchestration_run   - Run orchestration scenarios
  - mangle_query        - Query Mangle reasoning engine
  - kuzu_index          - Index AI SDK entities into KùzuDB graph
  - kuzu_query          - Read-only Cypher query against KùzuDB graph

Resources:
  - deployment://list   - AI Core deployments
  - mangle://facts      - Mangle fact store
  - mangle://rules      - Mangle reasoning rules

Prompts:
  - rag_query           - RAG query template
  - data_analysis       - Data analysis template
`);
});

} // end if (require.main === module)

export { MCPServer, httpServer };
