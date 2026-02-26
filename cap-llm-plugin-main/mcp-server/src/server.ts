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

let cachedToken: { token: string | null; expiresAt: number } = { token: null, expiresAt: 0 };

async function getAccessToken(config: CapLlmConfig): Promise<string> {
  if (cachedToken.token && Date.now() < cachedToken.expiresAt) {
    return cachedToken.token;
  }
  const auth = Buffer.from(`${config.clientId}:${config.clientSecret}`).toString('base64');
  return new Promise((resolve, reject) => {
    const url = new URL(config.authUrl);
    const req = https.request({
      hostname: url.hostname, port: 443, path: url.pathname, method: 'POST',
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

async function aiCoreRequest(config: CapLlmConfig, method: string, path: string, body?: unknown): Promise<unknown> {
  const token = await getAccessToken(config);
  const url = new URL(path, config.baseUrl);
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: url.hostname, port: 443, path: url.pathname + url.search, method,
      headers: { 'Authorization': `Bearer ${token}`, 'AI-Resource-Group': config.resourceGroup, 'Content-Type': 'application/json' },
    }, (res) => {
      let data = '';
      res.on('data', (chunk: string) => data += chunk);
      res.on('end', () => { try { resolve(JSON.parse(data)); } catch { resolve(data); } });
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
  }

  private registerResources(): void {
    this.resources.set('cap://services', { uri: 'cap://services', name: 'CAP Services', description: 'Available CAP services', mimeType: 'application/json' });
    this.resources.set('mangle://facts', { uri: 'mangle://facts', name: 'Mangle Facts', description: 'Mangle fact store', mimeType: 'application/json' });
    this.resources.set('mangle://rules', { uri: 'mangle://rules', name: 'Mangle Rules', description: 'Mangle rules', mimeType: 'text/plain' });
  }

  private initializeFacts(): void {
    this.facts.set('service_registry', [
      { name: 'cap-llm-chat', endpoint: 'cap://chat', model: 'claude-3.5-sonnet' },
      { name: 'cap-llm-rag', endpoint: 'cap://rag', model: 'rag-pipeline' },
      { name: 'cap-llm-vector', endpoint: 'cap://vector', model: 'hana-vector' },
    ]);
    this.facts.set('tool_invocation', []);
  }

  // Tool Handlers
  private async handleChat(args: Record<string, unknown>): Promise<unknown> {
    const config = getConfig();
    const messages = typeof args.messages === 'string' ? JSON.parse(args.messages as string) : args.messages;
    const deploymentsResult = await aiCoreRequest(config, 'GET', '/v2/lm/deployments') as { resources?: Array<{ id: string; details?: { resources?: { backend_details?: { model?: { name?: string } } } } }> };
    const deployments = deploymentsResult.resources || [];
    const deployment = deployments.find(d => d.details?.resources?.backend_details?.model?.name?.toLowerCase().includes('anthropic')) || deployments[0];
    if (!deployment) return { error: 'No deployment available' };
    this.facts.get('tool_invocation')?.push({ tool: 'cap_llm_chat', deployment: deployment.id, timestamp: Date.now() });
    const isAnthropic = deployment.details?.resources?.backend_details?.model?.name?.toLowerCase().includes('anthropic');
    if (isAnthropic) {
      const result = await aiCoreRequest(config, 'POST', `/v2/inference/deployments/${deployment.id}/invoke`, { anthropic_version: 'bedrock-2023-05-31', max_tokens: args.max_tokens || 1024, messages }) as { content?: Array<{ text?: string }> };
      return { content: result.content?.[0]?.text || '', model: deployment.id };
    }
    return await aiCoreRequest(config, 'POST', `/v2/inference/deployments/${deployment.id}/chat/completions`, { messages, max_tokens: args.max_tokens });
  }

  private async handleRag(args: Record<string, unknown>): Promise<unknown> {
    return { query: args.query, table_name: args.table_name, top_k: args.top_k || 5, status: 'RAG query placeholder - connect to HANA Cloud' };
  }

  private async handleVectorSearch(args: Record<string, unknown>): Promise<unknown> {
    return { query: args.query, table_name: args.table_name, top_k: args.top_k || 10, results: [], status: 'Connect to HANA Cloud for vector search' };
  }

  private async handleAnonymize(args: Record<string, unknown>): Promise<unknown> {
    return { text: args.text, entities: args.entities || '["PERSON", "EMAIL", "PHONE"]', anonymized: '[REDACTED]', status: 'Anonymization placeholder' };
  }

  private async handleEmbed(args: Record<string, unknown>): Promise<unknown> {
    const config = getConfig();
    const input = typeof args.input === 'string' ? (args.input.startsWith('[') ? JSON.parse(args.input as string) : [args.input]) : [args.input];
    const deploymentsResult = await aiCoreRequest(config, 'GET', '/v2/lm/deployments') as { resources?: Array<{ id: string; details?: { resources?: { backend_details?: { model?: { name?: string } } } } }> };
    const deployments = deploymentsResult.resources || [];
    const deployment = deployments.find(d => d.details?.resources?.backend_details?.model?.name?.toLowerCase().includes('embed')) || deployments[0];
    if (!deployment) return { error: 'No embedding deployment' };
    return await aiCoreRequest(config, 'POST', `/v2/inference/deployments/${deployment.id}/embeddings`, { input, model: args.model });
  }

  private async handleMangleQuery(args: Record<string, unknown>): Promise<unknown> {
    const predicate = args.predicate as string;
    const facts = this.facts.get(predicate);
    if (facts) return { predicate, results: facts };
    return { predicate, results: [], message: 'Unknown predicate' };
  }

  // MCP Protocol
  async handleRequest(request: MCPRequest): Promise<MCPResponse> {
    const { id, method, params } = request;
    try {
      switch (method) {
        case 'initialize':
          return { jsonrpc: '2.0', id, result: { protocolVersion: '2024-11-05', capabilities: { tools: { listChanged: true }, resources: { listChanged: true }, prompts: { listChanged: true } }, serverInfo: { name: 'cap-llm-mcp', version: '1.0.0' } } };
        case 'tools/list':
          return { jsonrpc: '2.0', id, result: { tools: Array.from(this.tools.values()) } };
        case 'tools/call':
          const handler = this.toolHandlers.get(params?.name as string);
          if (!handler) return { jsonrpc: '2.0', id, error: { code: -32602, message: `Unknown tool: ${params?.name}` } };
          const result = await handler((params?.arguments || {}) as Record<string, unknown>);
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

const PORT = parseInt(process.env.MCP_PORT || process.argv.find(a => a.startsWith('--port='))?.split('=')[1] || '9100');
const mcpServer = new MCPServer();

const httpServer = http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
  
  const url = new URL(req.url || '/', `http://${req.headers.host}`);
  
  if (url.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'healthy', service: 'cap-llm-mcp-server', timestamp: new Date().toISOString() }));
    return;
  }
  
  if (url.pathname === '/mcp' && req.method === 'POST') {
    let body = '';
    req.on('data', (chunk: string) => body += chunk);
    req.on('end', async () => {
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

const wss = new WebSocketServer({ server: httpServer, path: '/mcp/ws' });
wss.on('connection', (ws: WebSocket) => {
  ws.on('message', async (data: Buffer) => {
    try {
      const request = JSON.parse(data.toString()) as MCPRequest;
      const response = await mcpServer.handleRequest(request);
      ws.send(JSON.stringify(response));
    } catch { ws.send(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } })); }
  });
});

httpServer.listen(PORT, () => {
  console.log(`
╔══════════════════════════════════════════════════════════╗
║   CAP LLM Plugin MCP Server with Mangle Reasoning        ║
║   Model Context Protocol v2024-11-05                     ║
╚══════════════════════════════════════════════════════════╝

Server: http://localhost:${PORT}

Tools: cap_llm_chat, cap_llm_rag, cap_llm_vector_search,
       cap_llm_anonymize, cap_llm_embed, mangle_query

Resources: cap://services, mangle://facts, mangle://rules
`);
});

export { MCPServer, httpServer };