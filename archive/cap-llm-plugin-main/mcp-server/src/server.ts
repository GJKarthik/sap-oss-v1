// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * CAP LLM Plugin MCP Server
 * 
 * Model Context Protocol server with Mangle reasoning integration.
 * Provides tools for CAP LLM operations: RAG, anonymization, vector search.
 */

import * as http from 'http';
import * as https from 'https';
import { URL } from 'url';
import { WebSocketServer, WebSocket } from 'ws';

// Graph-RAG: load KùzuDB store with graceful fallback
let _getKuzuStore: (() => import('./kuzu-store').KuzuStore) | null = null;
try {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const kuzuMod = require('./kuzu-store');
  _getKuzuStore = kuzuMod.getKuzuStore as () => import('./kuzu-store').KuzuStore;
} catch {
  _getKuzuStore = null;
}

const MAX_JSON_BODY_BYTES = 1024 * 1024;
const MAX_TOOL_TOKENS = 8192;
const MAX_TOP_K = 100;
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

// =============================================================================
// CAP LLM Configuration
// =============================================================================

interface CapLlmConfig {
  clientId: string;
  clientSecret: string;
  authUrl: string;
  baseUrl: string;
  resourceGroup: string;
}

function getConfig(): CapLlmConfig {
  return {
    clientId: process.env.AICORE_CLIENT_ID || '',
    clientSecret: process.env.AICORE_CLIENT_SECRET || '',
    authUrl: process.env.AICORE_AUTH_URL || '',
    baseUrl: process.env.AICORE_BASE_URL || process.env.AICORE_SERVICE_URL || '',
    resourceGroup: process.env.AICORE_RESOURCE_GROUP || 'default',
  };
}

function validateConfig(config: CapLlmConfig): string | null {
  if (!config.clientId) return 'AICORE_CLIENT_ID is required';
  if (!config.clientSecret) return 'AICORE_CLIENT_SECRET is required';
  if (!config.authUrl) return 'AICORE_AUTH_URL is required';
  if (!config.baseUrl) return 'AICORE_BASE_URL (or AICORE_SERVICE_URL) is required';
  return null;
}

function safeJsonParse<T>(value: unknown, fallback: T): T {
  if (typeof value !== 'string') return fallback;
  try {
    return JSON.parse(value) as T;
  } catch {
    return fallback;
  }
}

function clampInt(value: unknown, defaultValue: number, minValue: number, maxValue: number): number {
  const parsed = Number.parseInt(String(value ?? defaultValue), 10);
  if (!Number.isFinite(parsed)) return defaultValue;
  if (parsed < minValue) return minValue;
  if (parsed > maxValue) return maxValue;
  return parsed;
}

function getRemoteMcpEndpoints(envKey: string): string[] {
  const raw = process.env[envKey] || '';
  return raw.split(',')
    .map(v => v.trim())
    .filter(Boolean)
    .map(v => v.endsWith('/mcp') ? v : `${v.replace(/\/+$/, '')}/mcp`);
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

let cachedToken: { token: string | null; expiresAt: number } = { token: null, expiresAt: 0 };
// In-flight refresh promise — coalesces concurrent callers to avoid thundering-herd on expiry
let _tokenRefreshPromise: Promise<string> | null = null;

async function getAccessToken(config: CapLlmConfig): Promise<string> {
  const configError = validateConfig(config);
  if (configError) throw new Error(configError);

  // Fast path — return cached token if still valid
  if (cachedToken.token && Date.now() < cachedToken.expiresAt) {
    return cachedToken.token;
  }

  // Coalesce concurrent refresh requests into one in-flight promise
  if (_tokenRefreshPromise) return _tokenRefreshPromise;

  _tokenRefreshPromise = (async (): Promise<string> => {
    const auth = Buffer.from(`${config.clientId}:${config.clientSecret}`).toString('base64');
    return new Promise<string>((resolve, reject) => {
      const url = new URL(config.authUrl);
      const req = https.request({
        hostname: url.hostname,
        port: url.port || 443,
        path: `${url.pathname}${url.search}`,
        method: 'POST',
        headers: { 'Authorization': `Basic ${auth}`, 'Content-Type': 'application/x-www-form-urlencoded' },
      }, (res) => {
        let data = '';
        res.on('data', (chunk: string) => data += chunk);
        res.on('end', () => {
          try {
            if (!res.statusCode || res.statusCode < 200 || res.statusCode >= 300) {
              return reject(new Error(`token request failed (${res.statusCode || 0}): ${data}`));
            }
            const result = JSON.parse(data) as { access_token?: string; expires_in?: number };
            if (!result.access_token) {
              return reject(new Error('token response missing access_token'));
            }
            const expiresIn = Math.max(120, result.expires_in || 3600);
            cachedToken = { token: result.access_token, expiresAt: Date.now() + (expiresIn - 60) * 1000 };
            resolve(result.access_token);
          } catch (e) { reject(e); }
        });
      });
      req.on('error', reject);
      req.write('grant_type=client_credentials');
      req.end();
    });
  })().finally(() => {
    // Drop the in-flight promise so the next expiry triggers a fresh fetch
    _tokenRefreshPromise = null;
  });

  return _tokenRefreshPromise;
}

async function aiCoreRequest(config: CapLlmConfig, method: string, path: string, body?: unknown): Promise<unknown> {
  const token = await getAccessToken(config);
  const url = new URL(path, config.baseUrl);
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: url.hostname,
      port: url.port || 443,
      path: url.pathname + url.search,
      method,
      headers: { 'Authorization': `Bearer ${token}`, 'AI-Resource-Group': config.resourceGroup, 'Content-Type': 'application/json' },
    }, (res) => {
      let data = '';
      res.on('data', (chunk: string) => data += chunk);
      res.on('end', () => {
        if (!res.statusCode || res.statusCode < 200 || res.statusCode >= 300) {
          return reject(new Error(`AI Core request failed (${res.statusCode || 0}): ${data}`));
        }
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
  private toolHandlers: Map<string, (args: Record<string, unknown>) => Promise<unknown>> = new Map();
  private facts: Map<string, unknown[]> = new Map();

  constructor() {
    this.registerTools();
    this.registerResources();
    this.initializeFacts();
  }

  private registerTools(): void {
    // Chat Completion
    this.tools.set('cap_llm_chat', {
      name: 'cap_llm_chat',
      description: 'Send chat completion via CAP LLM Plugin',
      inputSchema: {
        type: 'object',
        properties: {
          messages: { type: 'string', description: 'JSON array of messages [{role, content}]' },
          model: { type: 'string', description: 'Model ID or deployment ID' },
          max_tokens: { type: 'number', description: 'Maximum tokens' },
        },
        required: ['messages'],
      },
    });
    this.toolHandlers.set('cap_llm_chat', this.handleChat.bind(this));

    // RAG Query
    this.tools.set('cap_llm_rag', {
      name: 'cap_llm_rag',
      description: 'Retrieval-Augmented Generation query',
      inputSchema: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'User query' },
          table_name: { type: 'string', description: 'Vector table name' },
          top_k: { type: 'number', description: 'Number of documents to retrieve' },
        },
        required: ['query', 'table_name'],
      },
    });
    this.toolHandlers.set('cap_llm_rag', this.handleRag.bind(this));

    // Vector Search
    this.tools.set('cap_llm_vector_search', {
      name: 'cap_llm_vector_search',
      description: 'HANA Cloud vector similarity search',
      inputSchema: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'Search query' },
          table_name: { type: 'string', description: 'Vector table name' },
          top_k: { type: 'number', description: 'Results to return' },
        },
        required: ['query', 'table_name'],
      },
    });
    this.toolHandlers.set('cap_llm_vector_search', this.handleVectorSearch.bind(this));

    // Anonymization
    this.tools.set('cap_llm_anonymize', {
      name: 'cap_llm_anonymize',
      description: 'Anonymize text using HANA Cloud anonymization',
      inputSchema: {
        type: 'object',
        properties: {
          text: { type: 'string', description: 'Text to anonymize' },
          entities: { type: 'string', description: 'Entity types to anonymize (JSON array)' },
        },
        required: ['text'],
      },
    });
    this.toolHandlers.set('cap_llm_anonymize', this.handleAnonymize.bind(this));

    // Embedding
    this.tools.set('cap_llm_embed', {
      name: 'cap_llm_embed',
      description: 'Generate embeddings for text',
      inputSchema: {
        type: 'object',
        properties: {
          input: { type: 'string', description: 'Text to embed' },
          model: { type: 'string', description: 'Embedding model' },
        },
        required: ['input'],
      },
    });
    this.toolHandlers.set('cap_llm_embed', this.handleEmbed.bind(this));

    // Mangle Query
    this.tools.set('mangle_query', {
      name: 'mangle_query',
      description: 'Query the Mangle reasoning engine',
      inputSchema: {
        type: 'object',
        properties: {
          predicate: { type: 'string', description: 'Predicate to query' },
          args: { type: 'string', description: 'Arguments as JSON array' },
        },
        required: ['predicate'],
      },
    });
    this.toolHandlers.set('mangle_query', this.handleMangleQuery.bind(this));

    // Graph-RAG: index CAP LLM entities into KùzuDB
    this.tools.set('kuzu_index', {
      name: 'kuzu_index',
      description:
        'Index CAP LLM Plugin entities into the embedded KùzuDB graph database. ' +
        'Stores CapService nodes, LlmDeployment nodes, RagTable nodes, and their ' +
        'relationships (SERVED_BY, USES_TABLE, ROUTES_TO). ' +
        'Call before cap_llm_rag to enable graph-context enrichment.',
      inputSchema: {
        type: 'object',
        properties: {
          services: {
            type: 'string',
            description:
              'JSON array of service definitions: ' +
              '[{serviceId, serviceName?, serviceType?, dataClass?, servedBy?: string, usesTable?: string, routesTo?: string}]',
          },
          deployments: {
            type: 'string',
            description:
              'JSON array of deployment definitions: ' +
              '[{deploymentId, modelName?, resourceGroup?, status?}]',
          },
          ragTables: {
            type: 'string',
            description:
              'JSON array of RAG table definitions: ' +
              '[{tableId, tableName?, description?, schema?}]',
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
        'Use for service graph traversal, deployment lookup, RAG table discovery.',
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

  private registerResources(): void {
    this.resources.set('cap://services', { uri: 'cap://services', name: 'CAP Services', description: 'Available CAP services', mimeType: 'application/json' });
    this.resources.set('mangle://facts', { uri: 'mangle://facts', name: 'Mangle Facts', description: 'Mangle fact store', mimeType: 'application/json' });
    this.resources.set('mangle://rules', { uri: 'mangle://rules', name: 'Mangle Rules', description: 'Mangle rules', mimeType: 'text/plain' });
  }

  private initializeFacts(): void {
    const localPort = clampInt(process.env.MCP_PORT, 9100, 1, 65535);
    const serviceRegistry: Array<Record<string, unknown>> = [
      { name: 'cap-llm-chat', endpoint: 'cap://chat', model: 'claude-3.5-sonnet' },
      { name: 'cap-llm-rag', endpoint: 'cap://rag', model: 'rag-pipeline' },
      { name: 'cap-llm-vector', endpoint: 'cap://vector', model: 'hana-vector' },
      { name: 'cap-llm-mcp', endpoint: `http://localhost:${localPort}/mcp`, model: 'mcp-server' },
    ];
    getRemoteMcpEndpoints('CAP_LLM_REMOTE_MCP_ENDPOINTS').forEach((endpoint, index) => {
      serviceRegistry.push({ name: `remote-mcp-${index + 1}`, endpoint, model: 'federated' });
    });
    this.facts.set('service_registry', serviceRegistry);
    this.facts.set('tool_invocation', []);
  }

  // Tool Handlers
  private async handleChat(args: Record<string, unknown>): Promise<unknown> {
    const config = getConfig();
    const messages = typeof args.messages === 'string' ? safeJsonParse<unknown[]>(args.messages, []) : args.messages;
    if (!Array.isArray(messages) || messages.length === 0) {
      return { error: 'messages must be a non-empty array' };
    }
    const maxTokens = clampInt(args.max_tokens, 1024, 1, MAX_TOOL_TOKENS);
    const deploymentsResult = await aiCoreRequest(config, 'GET', '/v2/lm/deployments') as { resources?: Array<{ id: string; details?: { resources?: { backend_details?: { model?: { name?: string } } } } }> };
    const deployments = deploymentsResult.resources || [];
    const deployment = deployments.find(d => d.details?.resources?.backend_details?.model?.name?.toLowerCase().includes('anthropic')) || deployments[0];
    if (!deployment) return { error: 'No deployment available' };
    this.facts.get('tool_invocation')?.push({ tool: 'cap_llm_chat', deployment: deployment.id, timestamp: Date.now() });
    const isAnthropic = deployment.details?.resources?.backend_details?.model?.name?.toLowerCase().includes('anthropic');
    if (isAnthropic) {
      const result = await aiCoreRequest(config, 'POST', `/v2/inference/deployments/${deployment.id}/invoke`, { anthropic_version: 'bedrock-2023-05-31', max_tokens: maxTokens, messages }) as { content?: Array<{ text?: string }> };
      return { content: result.content?.[0]?.text || '', model: deployment.id };
    }
    return await aiCoreRequest(config, 'POST', `/v2/inference/deployments/${deployment.id}/chat/completions`, { messages, max_tokens: maxTokens });
  }

  private async handleRag(args: Record<string, unknown>): Promise<unknown> {
    const topK = clampInt(args.top_k, 5, 1, MAX_TOP_K);
    const base: Record<string, unknown> = { query: args.query, table_name: args.table_name, top_k: topK, status: 'RAG query placeholder - connect to HANA Cloud' };

    // C4 — attach graph context from KùzuDB when available
    if (_getKuzuStore) {
      const store = _getKuzuStore();
      if (store.available()) {
        const serviceId = String(args.service_id ?? args.table_name ?? '').trim();
        const tableId = String(args.table_name ?? '').trim();
        const [svcCtx, tblCtx] = await Promise.all([
          serviceId ? store.getServiceContext(serviceId) : Promise.resolve([]),
          tableId   ? store.getRagContext(tableId)       : Promise.resolve([]),
        ]);
        const ctx = [...svcCtx, ...tblCtx];
        if (ctx.length > 0) base['graphContext'] = ctx;
      }
    }

    return base;
  }

  private async handleVectorSearch(args: Record<string, unknown>): Promise<unknown> {
    const topK = clampInt(args.top_k, 10, 1, MAX_TOP_K);
    return { query: args.query, table_name: args.table_name, top_k: topK, results: [], status: 'Connect to HANA Cloud for vector search' };
  }

  private async handleAnonymize(args: Record<string, unknown>): Promise<unknown> {
    return { text: args.text, entities: args.entities || '["PERSON", "EMAIL", "PHONE"]', anonymized: '[REDACTED]', status: 'Anonymization placeholder' };
  }

  private async handleEmbed(args: Record<string, unknown>): Promise<unknown> {
    const config = getConfig();
    const input = typeof args.input === 'string'
      ? (args.input.startsWith('[') ? safeJsonParse<unknown[]>(args.input, []) : [args.input])
      : [args.input];
    if (!Array.isArray(input) || input.length === 0) {
      return { error: 'input must be provided' };
    }
    const deploymentsResult = await aiCoreRequest(config, 'GET', '/v2/lm/deployments') as { resources?: Array<{ id: string; details?: { resources?: { backend_details?: { model?: { name?: string } } } } }> };
    const deployments = deploymentsResult.resources || [];
    const deployment = deployments.find(d => d.details?.resources?.backend_details?.model?.name?.toLowerCase().includes('embed')) || deployments[0];
    if (!deployment) return { error: 'No embedding deployment' };
    return await aiCoreRequest(config, 'POST', `/v2/inference/deployments/${deployment.id}/embeddings`, { input, model: args.model });
  }

  private async handleMangleQuery(args: Record<string, unknown>): Promise<unknown> {
    const predicate = args.predicate as string;
    const queryArgs = Array.isArray(args.args)
      ? args.args
      : safeJsonParse<unknown[]>(args.args, []);
    const facts = this.facts.get(predicate);
    if (facts) return { predicate, results: facts };

    for (const endpoint of getRemoteMcpEndpoints('CAP_LLM_REMOTE_MCP_ENDPOINTS')) {
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

    return { predicate, results: [], message: 'Unknown predicate' };
  }

  // ---------------------------------------------------------------------------
  // Kuzu tool handlers
  // ---------------------------------------------------------------------------

  private async handleKuzuIndexTool(args: Record<string, unknown>): Promise<unknown> {
    if (!_getKuzuStore) {
      return { error: 'KùzuDB not available; add "kuzu": "^0.7.0" to mcp-server/package.json' };
    }
    const store = _getKuzuStore();
    if (!store.available()) {
      return { error: 'KùzuDB not installed; add "kuzu": "^0.7.0" to mcp-server/package.json' };
    }
    await store.ensureSchema();

    let servicesIndexed = 0;
    let deploymentsIndexed = 0;
    let ragTablesIndexed = 0;

    // Index deployments first (referenced by services)
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
      }
    }

    // Index RAG tables
    const rawTables = safeJsonParse<unknown[]>(args['ragTables'] as string ?? '[]', []);
    if (Array.isArray(rawTables)) {
      for (const t of rawTables) {
        if (!t || typeof t !== 'object') continue;
        const tbl = t as Record<string, unknown>;
        const tableId = String(tbl['tableId'] ?? '').trim();
        if (!tableId) continue;
        await store.upsertRagTable(
          tableId,
          String(tbl['tableName'] ?? ''),
          String(tbl['description'] ?? ''),
          String(tbl['schema'] ?? ''),
        );
        ragTablesIndexed++;
      }
    }

    // Index services + links
    const rawServices = safeJsonParse<unknown[]>(args['services'] as string ?? '[]', []);
    if (Array.isArray(rawServices)) {
      for (const s of rawServices) {
        if (!s || typeof s !== 'object') continue;
        const svc = s as Record<string, unknown>;
        const serviceId = String(svc['serviceId'] ?? '').trim();
        if (!serviceId) continue;
        await store.upsertService(
          serviceId,
          String(svc['serviceName'] ?? ''),
          String(svc['serviceType'] ?? ''),
          String(svc['dataClass'] ?? 'internal'),
        );
        servicesIndexed++;
        const servedBy = String(svc['servedBy'] ?? '').trim();
        if (servedBy) await store.linkServiceDeployment(serviceId, servedBy);
        const usesTable = String(svc['usesTable'] ?? '').trim();
        if (usesTable) await store.linkServiceTable(serviceId, usesTable);
        const routesTo = String(svc['routesTo'] ?? '').trim();
        if (routesTo) await store.linkServiceRoute(serviceId, routesTo);
      }
    }

    return { servicesIndexed, deploymentsIndexed, ragTablesIndexed };
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
    if (!_getKuzuStore) {
      return { error: 'KùzuDB not available; add "kuzu": "^0.7.0" to mcp-server/package.json' };
    }
    const store = _getKuzuStore();
    if (!store.available()) {
      return { error: 'KùzuDB not installed; add "kuzu": "^0.7.0" to mcp-server/package.json' };
    }
    const params = safeJsonParse<Record<string, unknown>>(args['params'] as string ?? '{}', {});
    const rows = await store.runQuery(cypher, typeof params === 'object' && params !== null ? params : {});
    return { rows, rowCount: rows.length };
  }

  // MCP Protocol
  async handleRequest(request: MCPRequest): Promise<MCPResponse> {
    const { id, method, params } = request;
    if (!request || request.jsonrpc !== '2.0' || typeof method !== 'string') {
      return { jsonrpc: '2.0', id: id ?? null, error: { code: -32600, message: 'Invalid Request' } };
    }
    if (params !== undefined && (params === null || typeof params !== 'object')) {
      return { jsonrpc: '2.0', id: id ?? null, error: { code: -32600, message: 'Invalid Request: params must be an object' } };
    }

    try {
      switch (method) {
        case 'initialize':
          return { jsonrpc: '2.0', id, result: { protocolVersion: '2024-11-05', capabilities: { tools: { listChanged: true }, resources: { listChanged: true }, prompts: { listChanged: true } }, serverInfo: { name: 'cap-llm-mcp', version: '1.0.0' } } };
        case 'tools/list':
          return { jsonrpc: '2.0', id, result: { tools: Array.from(this.tools.values()) } };
        case 'tools/call':
          if (typeof params?.name !== 'string') {
            return { jsonrpc: '2.0', id, error: { code: -32602, message: 'tools/call requires string param "name"' } };
          }
          const handler = this.toolHandlers.get(params.name);
          if (!handler) return { jsonrpc: '2.0', id, error: { code: -32602, message: `Unknown tool: ${params.name}` } };
          if (params.arguments !== undefined && (params.arguments === null || typeof params.arguments !== 'object' || Array.isArray(params.arguments))) {
            return { jsonrpc: '2.0', id, error: { code: -32602, message: 'tools/call param "arguments" must be an object' } };
          }
          const toolArgs = (params.arguments && typeof params.arguments === 'object')
            ? params.arguments as Record<string, unknown>
            : {};
          const result = await handler(toolArgs);
          return { jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] } };
        case 'resources/list':
          return { jsonrpc: '2.0', id, result: { resources: Array.from(this.resources.values()) } };
        case 'resources/read':
          if (params?.uri === 'mangle://facts') {
            const allFacts: Record<string, unknown> = {};
            this.facts.forEach((v, k) => { allFacts[k] = v; });
            return { jsonrpc: '2.0', id, result: { contents: [{ uri: params.uri, mimeType: 'application/json', text: JSON.stringify(allFacts, null, 2) }] } };
          }
          return { jsonrpc: '2.0', id, error: { code: -32602, message: `Unknown resource: ${params?.uri}` } };
        default:
          return { jsonrpc: '2.0', id, error: { code: -32601, message: `Method not found: ${method}` } };
      }
    } catch (error) {
      return { jsonrpc: '2.0', id, error: { code: -32603, message: String(error) } };
    }
  }
}

// =============================================================================
// HTTP Server
// =============================================================================

const requestedPort = parseInt(process.env.MCP_PORT || process.argv.find(a => a.startsWith('--port='))?.split('=')[1] || '9100', 10);
const PORT = Number.isInteger(requestedPort) && requestedPort > 0 && requestedPort <= 65535 ? requestedPort : 9100;
const mcpServer = new MCPServer();

// =============================================================================
// Bearer-token authentication
// Set MCP_AUTH_TOKEN to require a token on /mcp.
// Leave unset ONLY for fully-isolated localhost-only development.
// =============================================================================

const MCP_AUTH_TOKEN = (process.env.MCP_AUTH_TOKEN ?? '').trim();

if (!MCP_AUTH_TOKEN) {
  console.warn(
    'WARNING: MCP_AUTH_TOKEN is not set. The /mcp endpoint is unauthenticated. ' +
    'Set MCP_AUTH_TOKEN to a secure random token before any non-localhost deployment.',
  );
}

function checkBearerAuth(req: http.IncomingMessage): boolean {
  if (!MCP_AUTH_TOKEN) return true;
  const authHeader = (req.headers['authorization'] ?? '').trim();
  if (!authHeader.startsWith('Bearer ')) return false;
  return authHeader.slice('Bearer '.length).trim() === MCP_AUTH_TOKEN;
}

const corsAllowedOrigins = (process.env.CORS_ALLOWED_ORIGINS ?? 'http://localhost:3000,http://127.0.0.1:3000')
  .split(',')
  .map((o: string) => o.trim())
  .filter(Boolean);
const getCorsOrigin = (req: http.IncomingMessage): string | undefined => {
  const origin = req.headers.origin;
  if (origin && corsAllowedOrigins.includes(origin)) return origin;
  return corsAllowedOrigins[0];
};

const httpServer = http.createServer(async (req, res) => {
  const corsOrigin = getCorsOrigin(req);
  if (corsOrigin) res.setHeader('Access-Control-Allow-Origin', corsOrigin);
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
  
  const url = new URL(req.url || '/', `http://${req.headers.host}`);
  
  if (url.pathname === '/health') {
    const configError = validateConfig(getConfig());
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: configError ? 'degraded' : 'healthy',
      service: 'cap-llm-mcp-server',
      timestamp: new Date().toISOString(),
      configReady: !configError,
      ...(configError ? { configError } : {}),
    }));
    return;
  }
  
  if (url.pathname === '/mcp' && req.method === 'POST') {
    if (!checkBearerAuth(req)) {
      res.writeHead(401, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32001, message: 'Unauthorized: Bearer token required' } }));
      return;
    }
    let body = '';
    let rejected = false;
    req.on('data', (chunk: string) => {
      if (rejected) return;
      body += chunk;
      if (body.length > MAX_JSON_BODY_BYTES) {
        rejected = true;
        res.writeHead(413, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32600, message: 'Request too large' } }));
        req.destroy();
      }
    });
    req.on('end', async () => {
      if (rejected || res.writableEnded) return;
      try {
        const request = JSON.parse(body) as MCPRequest;
        const response = await mcpServer.handleRequest(request);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(response));
      } catch {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }));
      }
    });
    return;
  }
  
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

const wss = new WebSocketServer({ server: httpServer, path: '/mcp/ws', handleProtocols: () => false });
wss.on('headers', (headers: string[], req: http.IncomingMessage) => {
  if (!checkBearerAuth(req)) {
    headers.push('HTTP/1.1 401 Unauthorized');
  }
});
wss.on('connection', (ws: WebSocket, req: http.IncomingMessage) => {
  if (!checkBearerAuth(req)) {
    ws.close(1008, 'Unauthorized');
    return;
  }
  ws.on('message', async (data: Buffer) => {
    if (data.length > MAX_JSON_BODY_BYTES) {
      ws.send(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32600, message: 'Request too large' } }));
      ws.close(1009, 'message too big');
      return;
    }

    try {
      const request = JSON.parse(data.toString()) as MCPRequest;
      const response = await mcpServer.handleRequest(request);
      ws.send(JSON.stringify(response));
    } catch { ws.send(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } })); }
  });
});

if (require.main === module) {
httpServer.listen(PORT, () => {
  console.log(`
╔══════════════════════════════════════════════════════════╗
║   CAP LLM Plugin MCP Server with Mangle Reasoning        ║
║   Model Context Protocol v2024-11-05                     ║
╚══════════════════════════════════════════════════════════╝

Server: http://localhost:${PORT}

Tools: cap_llm_chat, cap_llm_rag, cap_llm_vector_search,
       cap_llm_anonymize, cap_llm_embed, mangle_query,
       kuzu_index, kuzu_query

Resources: cap://services, mangle://facts, mangle://rules
`);
});

} // end if (require.main === module)

export { MCPServer, httpServer };
