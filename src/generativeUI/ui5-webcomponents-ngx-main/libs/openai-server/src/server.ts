// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * SAP OpenAI-Compatible Server for UI5 Web Components NGX
 * 
 * Full OpenAI API-compliant server routing to SAP AI Core.
 * Built with Node.js for the Angular/NX project.
 * 
 * Usage:
 *   npx ts-node libs/openai-server/src/server.ts --port 8400
 */

import * as http from 'http';
import * as https from 'https';
import { URL } from 'url';

// =============================================================================
// Configuration
// =============================================================================

interface AICoreConfig {
  clientId: string;
  clientSecret: string;
  authUrl: string;
  baseUrl: string;
  resourceGroup: string;
  chatDeploymentId?: string;
  embeddingDeploymentId?: string;
}

function getConfig(): AICoreConfig {
  return {
    clientId: process.env['AICORE_CLIENT_ID'] || '',
    clientSecret: process.env['AICORE_CLIENT_SECRET'] || '',
    authUrl: process.env['AICORE_AUTH_URL'] || '',
    baseUrl: process.env['AICORE_BASE_URL'] || process.env['AICORE_SERVICE_URL'] || '',
    resourceGroup: process.env['AICORE_RESOURCE_GROUP'] || 'default',
    chatDeploymentId: process.env['AICORE_CHAT_DEPLOYMENT_ID'],
    embeddingDeploymentId: process.env['AICORE_EMBEDDING_DEPLOYMENT_ID'],
  };
}

// =============================================================================
// Token Cache
// =============================================================================

let cachedToken: { token: string | null; expiresAt: number } = { token: null, expiresAt: 0 };

async function getAccessToken(config: AICoreConfig): Promise<string> {
  if (cachedToken.token && Date.now() < cachedToken.expiresAt) {
    return cachedToken.token;
  }

  const auth = Buffer.from(`${config.clientId}:${config.clientSecret}`).toString('base64');
  
  return new Promise((resolve, reject) => {
    const url = new URL(config.authUrl);
    const options: https.RequestOptions = {
      hostname: url.hostname,
      port: url.port || 443,
      path: url.pathname,
      method: 'POST',
      headers: {
        'Authorization': `Basic ${auth}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
    };

    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', (chunk: string) => data += chunk);
      res.on('end', () => {
        try {
          const result = JSON.parse(data);
          cachedToken.token = result.access_token;
          cachedToken.expiresAt = Date.now() + (result.expires_in - 60) * 1000;
          resolve(result.access_token);
        } catch (e) {
          reject(e);
        }
      });
    });

    req.on('error', reject);
    req.write('grant_type=client_credentials');
    req.end();
  });
}

// =============================================================================
// AI Core Request
// =============================================================================

interface Deployment {
  id: string;
  model: string;
  status: string;
  isAnthropic: boolean;
}

let cachedDeployments: Deployment[] = [];

async function aicoreRequest(config: AICoreConfig, method: string, path: string, body?: unknown): Promise<unknown> {
  const token = await getAccessToken(config);
  const url = new URL(path, config.baseUrl);
  
  return new Promise((resolve, reject) => {
    const options: https.RequestOptions = {
      hostname: url.hostname,
      port: url.port || 443,
      path: url.pathname + url.search,
      method,
      headers: {
        'Authorization': `Bearer ${token}`,
        'AI-Resource-Group': config.resourceGroup,
        'Content-Type': 'application/json',
      },
    };

    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', (chunk: string) => data += chunk);
      res.on('end', () => {
        try {
          resolve(JSON.parse(data));
        } catch {
          resolve(data);
        }
      });
    });

    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

async function getDeployments(config: AICoreConfig): Promise<Deployment[]> {
  if (cachedDeployments.length > 0) return cachedDeployments;
  
  const result = await aicoreRequest(config, 'GET', '/v2/lm/deployments') as { resources?: Array<{ id: string; status?: string; details?: { resources?: { backend_details?: { model?: { name?: string } } } } }> };
  cachedDeployments = (result.resources || []).map(d => ({
    id: d.id,
    model: d.details?.resources?.backend_details?.model?.name || 'unknown',
    status: d.status || 'unknown',
    isAnthropic: (d.details?.resources?.backend_details?.model?.name || '').toLowerCase().includes('anthropic'),
  }));
  
  return cachedDeployments;
}

function findDeployment(deployments: Deployment[], modelId: string): Deployment | undefined {
  return deployments.find(d => d.id === modelId) ||
         deployments.find(d => d.model === modelId || modelId.includes(d.model) || d.model.includes(modelId)) ||
         deployments.find(d => modelId.substring(0, 8).includes(d.id.substring(0, 8)));
}

// =============================================================================
// In-Memory Storage
// =============================================================================

const fileStorage: Map<string, Record<string, unknown>> = new Map();
const assistants: Map<string, Record<string, unknown>> = new Map();
const threads: Map<string, Record<string, unknown>> = new Map();
const messages: Map<string, Array<Record<string, unknown>>> = new Map();
const runs: Map<string, Record<string, unknown>> = new Map();
const batches: Map<string, Record<string, unknown>> = new Map();
const vectorTables: Map<string, Array<Record<string, unknown>>> = new Map();

// =============================================================================
// Utility Functions
// =============================================================================

function uuid(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = Math.random() * 16 | 0;
    return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
  });
}

function cosineSimilarity(a: number[], b: number[]): number {
  if (a.length !== b.length || a.length === 0) return 0;
  let dot = 0, normA = 0, normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  return dot / (Math.sqrt(normA) * Math.sqrt(normB)) || 0;
}

// =============================================================================
// Request Handler
// =============================================================================

async function parseBody(req: http.IncomingMessage): Promise<Record<string, unknown>> {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (chunk: string) => data += chunk);
    req.on('end', () => {
      try {
        resolve(JSON.parse(data));
      } catch {
        resolve({});
      }
    });
  });
}

function sendJson(res: http.ServerResponse, status: number, data: unknown, corsOrigin = '*'): void {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': corsOrigin });
  res.end(JSON.stringify(data));
}

function sendError(res: http.ServerResponse, status: number, message: string): void {
  sendJson(res, status, { error: { message, type: 'api_error', code: status } });
}

// =============================================================================
// Internal-token guard for HANA vector routes
// =============================================================================

const OPENAI_INTERNAL_TOKEN = (process.env.OPENAI_INTERNAL_TOKEN ?? '').trim();
const OPENAI_ALLOWED_ORIGINS = (process.env.OPENAI_ALLOWED_ORIGINS ?? '').trim()
  .split(',').map(o => o.trim()).filter(Boolean);

if (!OPENAI_INTERNAL_TOKEN) {
  console.warn(
    'WARNING: OPENAI_INTERNAL_TOKEN is not set. ' +
    '/v1/hana/* endpoints are unauthenticated and proxy a production HANA Cloud instance. ' +
    'Set OPENAI_INTERNAL_TOKEN to a secure random token and ensure this server is ' +
    'accessible only within a trusted network segment.',
  );
}

function checkInternalToken(req: http.IncomingMessage, res: http.ServerResponse): boolean {
  if (!OPENAI_INTERNAL_TOKEN) return true;
  const provided = (req.headers['x-internal-token'] ?? '').toString().trim();
  if (provided !== OPENAI_INTERNAL_TOKEN) {
    sendJson(res, 401, { error: { message: 'Unauthorized: X-Internal-Token required for HANA routes', type: 'auth_error', code: 401 } });
    return false;
  }
  return true;
}

function getAllowedOrigin(req: http.IncomingMessage): string {
  if (OPENAI_ALLOWED_ORIGINS.length === 0) return '*';
  const origin = (req.headers['origin'] ?? '').toString().trim();
  if (origin && OPENAI_ALLOWED_ORIGINS.includes(origin)) return origin;
  return OPENAI_ALLOWED_ORIGINS[0] ?? '';
}

async function handleRequest(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
  // CORS
  if (req.method === 'OPTIONS') {
    const allowedOrigin = getAllowedOrigin(req);
    res.writeHead(204, {
      'Access-Control-Allow-Origin': allowedOrigin,
      'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Internal-Token',
    });
    res.end();
    return;
  }

  const url = new URL(req.url || '/', `http://${req.headers.host}`);
  const path = url.pathname;
  const method = req.method || 'GET';
  const config = getConfig();

  try {
    // Health
    if (path === '/health') {
      return sendJson(res, 200, { 
        status: 'healthy', 
        service: 'sap-openai-server-ui5-ngx',
        timestamp: new Date().toISOString()
      });
    }

    // Models
    if (path === '/v1/models' && method === 'GET') {
      const deployments = await getDeployments(config);
      return sendJson(res, 200, {
        object: 'list',
        data: deployments.map(d => ({
          id: d.id,
          object: 'model',
          created: Math.floor(Date.now() / 1000),
          owned_by: d.isAnthropic ? 'anthropic' : 'openai',
          root: d.model,
        }))
      });
    }

    if (/^\/v1\/models\/[\w-]+$/.test(path) && method === 'GET') {
      const modelId = path.split('/').pop()!;
      const deployments = await getDeployments(config);
      const deployment = findDeployment(deployments, modelId);
      if (!deployment) return sendError(res, 404, 'Model not found');
      return sendJson(res, 200, {
        id: deployment.id,
        object: 'model',
        created: Math.floor(Date.now() / 1000),
        owned_by: deployment.isAnthropic ? 'anthropic' : 'openai',
        root: deployment.model,
      });
    }

    // Chat Completions
    if (path === '/v1/chat/completions' && method === 'POST') {
      const body = await parseBody(req);
      const deployments = await getDeployments(config);
      let deployment = findDeployment(deployments, body['model'] as string);
      if (!deployment && config.chatDeploymentId) deployment = findDeployment(deployments, config.chatDeploymentId);
      if (!deployment) return sendError(res, 400, `Model ${body['model']} not found`);

      const completionId = `chatcmpl-${uuid()}`;
      const created = Math.floor(Date.now() / 1000);

      if (deployment.isAnthropic) {
        const result = await aicoreRequest(config, 'POST',
          `/v2/inference/deployments/${deployment.id}/invoke`,
          {
            anthropic_version: 'bedrock-2023-05-31',
            max_tokens: body['max_tokens'] || 1024,
            messages: body['messages'],
          }
        ) as { content?: Array<{ text?: string }>; usage?: { input_tokens?: number; output_tokens?: number } };

        const content = result.content?.[0]?.text || '';
        const inputTokens = result.usage?.input_tokens || 0;
        const outputTokens = result.usage?.output_tokens || 0;

        return sendJson(res, 200, {
          id: completionId,
          object: 'chat.completion',
          created,
          model: deployment.id,
          choices: [{
            index: 0,
            message: { role: 'assistant', content },
            finish_reason: 'stop',
          }],
          usage: {
            prompt_tokens: inputTokens,
            completion_tokens: outputTokens,
            total_tokens: inputTokens + outputTokens,
          },
        });
      } else {
        const result = await aicoreRequest(config, 'POST',
          `/v2/inference/deployments/${deployment.id}/chat/completions`,
          {
            model: body['model'],
            messages: body['messages'],
            max_tokens: body['max_tokens'],
            temperature: body['temperature'],
          }
        );
        return sendJson(res, 200, { id: completionId, ...result as object, model: deployment.id });
      }
    }

    // Embeddings
    if (path === '/v1/embeddings' && method === 'POST') {
      const body = await parseBody(req);
      const deployments = await getDeployments(config);
      let deployment = findDeployment(deployments, body['model'] as string);
      if (!deployment) deployment = deployments.find(d => d.model.toLowerCase().includes('embed')) || deployments[0];
      if (!deployment) return sendError(res, 400, 'No embedding model available');

      const inputs = Array.isArray(body['input']) ? body['input'] : [body['input']];
      const result = await aicoreRequest(config, 'POST',
        `/v2/inference/deployments/${deployment.id}/embeddings`,
        { input: inputs, model: body['model'] }
      ) as { data?: unknown[]; usage?: unknown };

      return sendJson(res, 200, {
        object: 'list',
        data: result.data || [],
        model: deployment.id,
        usage: result.usage || { prompt_tokens: 0, total_tokens: 0 },
      });
    }

    // Files
    if (path === '/v1/files' && method === 'GET') {
      return sendJson(res, 200, {
        object: 'list',
        data: Array.from(fileStorage.values()).map(f => ({
          id: f['id'],
          object: 'file',
          bytes: f['bytes'],
          created_at: f['created_at'],
          filename: f['filename'],
          purpose: f['purpose'],
          status: 'processed',
        }))
      });
    }

    if (path === '/v1/files' && method === 'POST') {
      const body = await parseBody(req);
      const fileId = `file-${uuid()}`;
      const createdAt = Math.floor(Date.now() / 1000);
      fileStorage.set(fileId, {
        id: fileId,
        filename: body['filename'] || fileId,
        purpose: body['purpose'] || 'search',
        bytes: (body['file'] as string)?.length || 0,
        content: body['file'],
        created_at: createdAt,
      });
      return sendJson(res, 200, { id: fileId, object: 'file', bytes: (body['file'] as string)?.length || 0, created_at: createdAt, filename: body['filename'] || fileId, purpose: body['purpose'] || 'search', status: 'processed' });
    }

    if (/^\/v1\/files\/[\w-]+$/.test(path) && method === 'DELETE') {
      const fileId = path.split('/').pop()!;
      if (!fileStorage.has(fileId)) return sendError(res, 404, 'File not found');
      fileStorage.delete(fileId);
      return sendJson(res, 200, { id: fileId, object: 'file', deleted: true });
    }

    // Moderations
    if (path === '/v1/moderations' && method === 'POST') {
      const body = await parseBody(req);
      const inputs = Array.isArray(body['input']) ? body['input'] : [body['input']];
      return sendJson(res, 200, {
        id: `modr-${uuid()}`,
        model: body['model'] || 'text-moderation-latest',
        results: inputs.map(() => ({
          flagged: false,
          categories: { hate: false, violence: false, 'self-harm': false, sexual: false },
          category_scores: { hate: 0, violence: 0, 'self-harm': 0, sexual: 0 },
        }))
      });
    }

    // Assistants
    if (path === '/v1/assistants' && method === 'GET') {
      const list = Array.from(assistants.values()).sort((a, b) => (b['created_at'] as number) - (a['created_at'] as number));
      return sendJson(res, 200, { object: 'list', data: list.slice(0, 20), first_id: list[0]?.['id'], last_id: list[list.length - 1]?.['id'], has_more: list.length > 20 });
    }

    if (path === '/v1/assistants' && method === 'POST') {
      const body = await parseBody(req);
      const assistantId = `asst_${uuid().replace(/-/g, '').substring(0, 24)}`;
      const created_at = Math.floor(Date.now() / 1000);
      const assistant = {
        id: assistantId,
        object: 'assistant',
        created_at,
        name: body['name'],
        description: body['description'],
        model: body['model'],
        instructions: body['instructions'],
        tools: body['tools'] || [],
        file_ids: body['file_ids'] || [],
        metadata: body['metadata'] || {},
      };
      assistants.set(assistantId, assistant);
      return sendJson(res, 200, assistant);
    }

    if (/^\/v1\/assistants\/asst_[\w]+$/.test(path) && method === 'DELETE') {
      const assistantId = path.split('/').pop()!;
      if (!assistants.has(assistantId)) return sendError(res, 404, 'Assistant not found');
      assistants.delete(assistantId);
      return sendJson(res, 200, { id: assistantId, object: 'assistant.deleted', deleted: true });
    }

    // Threads
    if (path === '/v1/threads' && method === 'POST') {
      const body = await parseBody(req);
      const threadId = `thread_${uuid().replace(/-/g, '').substring(0, 24)}`;
      const created_at = Math.floor(Date.now() / 1000);
      const thread = { id: threadId, object: 'thread', created_at, metadata: body['metadata'] || {} };
      threads.set(threadId, thread);
      messages.set(threadId, []);
      return sendJson(res, 200, thread);
    }

    if (/^\/v1\/threads\/thread_[\w]+$/.test(path) && method === 'DELETE') {
      const threadId = path.split('/').pop()!;
      if (!threads.has(threadId)) return sendError(res, 404, 'Thread not found');
      threads.delete(threadId);
      messages.delete(threadId);
      return sendJson(res, 200, { id: threadId, object: 'thread.deleted', deleted: true });
    }

    // Thread Messages
    if (/^\/v1\/threads\/thread_[\w]+\/messages$/.test(path) && method === 'GET') {
      const threadId = path.split('/')[3];
      if (!threads.has(threadId)) return sendError(res, 404, 'Thread not found');
      const msgs = messages.get(threadId) || [];
      return sendJson(res, 200, { object: 'list', data: msgs.slice().reverse().slice(0, 20), first_id: msgs[0]?.['id'], last_id: msgs[msgs.length - 1]?.['id'], has_more: msgs.length > 20 });
    }

    if (/^\/v1\/threads\/thread_[\w]+\/messages$/.test(path) && method === 'POST') {
      const body = await parseBody(req);
      const threadId = path.split('/')[3];
      if (!threads.has(threadId)) return sendError(res, 404, 'Thread not found');
      const messageId = `msg_${uuid().replace(/-/g, '').substring(0, 24)}`;
      const created_at = Math.floor(Date.now() / 1000);
      const message = {
        id: messageId,
        object: 'thread.message',
        created_at,
        thread_id: threadId,
        role: body['role'],
        content: [{ type: 'text', text: { value: body['content'], annotations: [] } }],
        file_ids: body['file_ids'] || [],
        assistant_id: null,
        run_id: null,
        metadata: body['metadata'] || {},
      };
      messages.get(threadId)!.push(message);
      return sendJson(res, 200, message);
    }

    // Batches
    if (path === '/v1/batches' && method === 'GET') {
      return sendJson(res, 200, { object: 'list', data: Array.from(batches.values()).slice(0, 20) });
    }

    if (path === '/v1/batches' && method === 'POST') {
      const body = await parseBody(req);
      const batchId = `batch_${uuid().replace(/-/g, '').substring(0, 24)}`;
      const created_at = Math.floor(Date.now() / 1000);
      const batch = {
        id: batchId,
        object: 'batch',
        endpoint: body['endpoint'],
        input_file_id: body['input_file_id'],
        completion_window: body['completion_window'] || '24h',
        status: 'validating',
        created_at,
        metadata: body['metadata'] || {},
      };
      batches.set(batchId, batch);
      return sendJson(res, 200, batch);
    }

    // Vector Store — protected by X-Internal-Token
    if (path === '/v1/hana/tables' && method === 'GET') {
      if (!checkInternalToken(req, res)) return;
      return sendJson(res, 200, { object: 'list', data: Array.from(vectorTables.keys()), source: 'memory' });
    }

    if (path === '/v1/hana/vectors' && method === 'POST') {
      if (!checkInternalToken(req, res)) return;
      const body = await parseBody(req);
      const tableName = body['table_name'] as string;
      if (!tableName) return sendError(res, 400, 'table_name is required');
      
      const deployments = await getDeployments(config);
      const deployment = deployments.find(d => d.model.toLowerCase().includes('embed')) || deployments[0];
      if (!deployment) return sendError(res, 400, 'No embedding model available');
      
      const result = await aicoreRequest(config, 'POST',
        `/v2/inference/deployments/${deployment.id}/embeddings`,
        { input: body['documents'] }
      ) as { data?: Array<{ embedding?: number[] }> };
      
      const embeddings = (result.data || []).map(d => d.embedding || []);
      const ids = (body['ids'] as string[]) || (body['documents'] as string[]).map(() => `doc-${uuid()}`);
      
      if (!vectorTables.has(tableName)) vectorTables.set(tableName, []);
      const table = vectorTables.get(tableName)!;
      
      (body['documents'] as string[]).forEach((doc, i) => {
        table.push({ id: ids[i], content: doc, embedding: embeddings[i] });
      });
      
      return sendJson(res, 200, { status: 'stored', table_name: tableName, documents_stored: (body['documents'] as string[]).length, model: deployment.id });
    }

    if (path === '/v1/hana/search' && method === 'POST') {
      if (!checkInternalToken(req, res)) return;
      const body = await parseBody(req);
      const tableName = body['vector_table'] as string;
      if (!tableName) return sendError(res, 400, 'vector_table is required');
      
      const table = vectorTables.get(tableName);
      if (!table || table.length === 0) return sendJson(res, 200, { object: 'list', data: [] });
      
      const deployments = await getDeployments(config);
      const deployment = deployments.find(d => d.model.toLowerCase().includes('embed')) || deployments[0];
      if (!deployment) return sendError(res, 400, 'No embedding model available');
      
      const result = await aicoreRequest(config, 'POST',
        `/v2/inference/deployments/${deployment.id}/embeddings`,
        { input: [body['query']] }
      ) as { data?: Array<{ embedding?: number[] }> };
      
      const queryEmb = result.data?.[0]?.embedding || [];
      const scores = table.map((doc, i) => ({
        document: i,
        score: cosineSimilarity(queryEmb, doc['embedding'] as number[]),
        text: doc['content'],
      })).sort((a, b) => b.score - a.score).slice(0, (body['max_rerank'] as number) || 10);
      
      return sendJson(res, 200, { object: 'list', data: scores.map(s => ({ object: 'search_result', ...s })), model: deployment.id, source: 'memory' });
    }

    // Not found
    return sendError(res, 404, `Endpoint ${path} not found`);
  } catch (error) {
    console.error('Error:', error);
    return sendError(res, 500, String(error));
  }
}

// =============================================================================
// Server
// =============================================================================

const PORT = parseInt(process.env['PORT'] || process.argv.find(a => a.startsWith('--port='))?.split('=')[1] || '8400');

const server = http.createServer(handleRequest);

server.listen(PORT, () => {
  console.log(`
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║   SAP OpenAI-Compatible Server (UI5 Web Components NGX)  ║
║   Powered by SAP AI Core                                 ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝

Server running at: http://localhost:${PORT}

Endpoints:
  GET  /health              - Health check
  GET  /v1/models           - List models
  POST /v1/chat/completions - Chat completions
  POST /v1/embeddings       - Embeddings
  GET  /v1/files            - Files
  POST /v1/moderations      - Moderation
  GET  /v1/assistants       - Assistants
  POST /v1/threads          - Threads
  GET  /v1/batches          - Batches
  GET  /v1/hana/tables      - Vector tables
`);
});

export { server, handleRequest };