// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2019 SAP SE
/**
 * SAP OpenAI-Compatible Server for OData Vocabularies
 * 
 * Full OpenAI API-compliant server routing to SAP AI Core.
 * Built with Express for the OData vocabularies project.
 * 
 * Usage:
 *   node sap_openai_server/server.js --port 8500
 */

const http = require('http');
const https = require('https');
const { URL } = require('url');

// =============================================================================
// Configuration
// =============================================================================

const CORS_ALLOWED_ORIGINS = (process.env.CORS_ALLOWED_ORIGINS || 'http://localhost:3000,http://127.0.0.1:3000')
  .split(',')
  .map((o) => o.trim())
  .filter(Boolean);

function getCorsOrigin(req) {
  const origin = (req && req.headers && req.headers.origin) ? req.headers.origin.trim() : '';
  if (origin && CORS_ALLOWED_ORIGINS.includes(origin)) return origin;
  return CORS_ALLOWED_ORIGINS[0] || null;
}

function getConfig() {
  return {
    clientId: process.env.AICORE_CLIENT_ID || '',
    clientSecret: process.env.AICORE_CLIENT_SECRET || '',
    authUrl: process.env.AICORE_AUTH_URL || '',
    baseUrl: process.env.AICORE_BASE_URL || process.env.AICORE_SERVICE_URL || '',
    resourceGroup: process.env.AICORE_RESOURCE_GROUP || 'default',
  };
}

// Token cache
let cachedToken = { token: null, expiresAt: 0 };

async function getAccessToken(config) {
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
      res.on('data', chunk => data += chunk);
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

async function aicoreRequest(config, method, path, body) {
  const token = await getAccessToken(config);
  const url = new URL(path, config.baseUrl);
  
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: url.hostname,
      port: 443,
      path: url.pathname + url.search,
      method,
      headers: { 'Authorization': `Bearer ${token}`, 'AI-Resource-Group': config.resourceGroup, 'Content-Type': 'application/json' },
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); } catch { resolve(data); }
      });
    });
    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

let cachedDeployments = [];

async function getDeployments(config) {
  if (cachedDeployments.length > 0) return cachedDeployments;
  const result = await aicoreRequest(config, 'GET', '/v2/lm/deployments');
  cachedDeployments = (result.resources || []).map(d => ({
    id: d.id,
    model: d.details?.resources?.backend_details?.model?.name || 'unknown',
    status: d.status || 'unknown',
    isAnthropic: (d.details?.resources?.backend_details?.model?.name || '').toLowerCase().includes('anthropic'),
  }));
  return cachedDeployments;
}

function findDeployment(deployments, modelId) {
  return deployments.find(d => d.id === modelId) ||
         deployments.find(d => d.model === modelId || modelId.includes(d.model) || d.model.includes(modelId)) ||
         deployments[0];
}

// Storage
const fileStorage = new Map();
const assistants = new Map();
const threads = new Map();
const messages = new Map();
const batches = new Map();
const vectorTables = new Map();

function uuid() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = Math.random() * 16 | 0;
    return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
  });
}

// =============================================================================
// Request Handler
// =============================================================================

async function parseBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', chunk => data += chunk);
    req.on('end', () => {
      try { resolve(JSON.parse(data)); } catch { resolve({}); }
    });
  });
}

function sendJson(res, status, data, origin) {
  const headers = { 'Content-Type': 'application/json' };
  if (origin) headers['Access-Control-Allow-Origin'] = origin;
  res.writeHead(status, headers);
  res.end(JSON.stringify(data));
}

function sendError(res, status, message, origin) {
  sendJson(res, status, { error: { message, type: 'api_error', code: status } }, origin);
}

async function handleRequest(req, res) {
  const corsOrigin = getCorsOrigin(req);
  if (req.method === 'OPTIONS') {
    const headers = {
      'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    };
    if (corsOrigin) headers['Access-Control-Allow-Origin'] = corsOrigin;
    res.writeHead(204, headers);
    return res.end();
  }

  const url = new URL(req.url || '/', `http://${req.headers.host}`);
  const path = url.pathname;
  const method = req.method;
  const config = getConfig();

  try {
    // Health
    if (path === '/health') {
      return sendJson(res, 200, { status: 'healthy', service: 'sap-openai-server-odata-vocab', timestamp: new Date().toISOString() }, corsOrigin);
    }

    // Models
    if (path === '/v1/models' && method === 'GET') {
      const deployments = await getDeployments(config);
      return sendJson(res, 200, {
        object: 'list',
        data: deployments.map(d => ({ id: d.id, object: 'model', created: Math.floor(Date.now() / 1000), owned_by: d.isAnthropic ? 'anthropic' : 'openai', root: d.model }))
      }, corsOrigin);
    }

    // Chat Completions
    if (path === '/v1/chat/completions' && method === 'POST') {
      const body = await parseBody(req);
      const deployments = await getDeployments(config);
      const deployment = findDeployment(deployments, body.model);
      if (!deployment) return sendError(res, 400, `Model ${body.model} not found`, corsOrigin);

      const completionId = `chatcmpl-${uuid()}`;
      const created = Math.floor(Date.now() / 1000);

      if (deployment.isAnthropic) {
        const result = await aicoreRequest(config, 'POST', `/v2/inference/deployments/${deployment.id}/invoke`, {
          anthropic_version: 'bedrock-2023-05-31', max_tokens: body.max_tokens || 1024, messages: body.messages,
        });
        const content = result.content?.[0]?.text || '';
        return sendJson(res, 200, {
          id: completionId, object: 'chat.completion', created, model: deployment.id,
          choices: [{ index: 0, message: { role: 'assistant', content }, finish_reason: 'stop' }],
          usage: { prompt_tokens: result.usage?.input_tokens || 0, completion_tokens: result.usage?.output_tokens || 0, total_tokens: (result.usage?.input_tokens || 0) + (result.usage?.output_tokens || 0) },
        }, corsOrigin);
      } else {
        const result = await aicoreRequest(config, 'POST', `/v2/inference/deployments/${deployment.id}/chat/completions`, {
          model: body.model, messages: body.messages, max_tokens: body.max_tokens, temperature: body.temperature,
        });
        return sendJson(res, 200, { id: completionId, ...result, model: deployment.id }, corsOrigin);
      }
    }

    // Embeddings
    if (path === '/v1/embeddings' && method === 'POST') {
      const body = await parseBody(req);
      const deployments = await getDeployments(config);
      const deployment = deployments.find(d => d.model.toLowerCase().includes('embed')) || deployments[0];
      if (!deployment) return sendError(res, 400, 'No embedding model available', corsOrigin);
      const inputs = Array.isArray(body.input) ? body.input : [body.input];
      const result = await aicoreRequest(config, 'POST', `/v2/inference/deployments/${deployment.id}/embeddings`, { input: inputs, model: body.model });
      return sendJson(res, 200, { object: 'list', data: result.data || [], model: deployment.id, usage: result.usage || { prompt_tokens: 0, total_tokens: 0 } }, corsOrigin);
    }

    // Files
    if (path === '/v1/files' && method === 'GET') {
      return sendJson(res, 200, { object: 'list', data: Array.from(fileStorage.values()).map(f => ({ id: f.id, object: 'file', bytes: f.bytes, created_at: f.created_at, filename: f.filename, purpose: f.purpose, status: 'processed' })) }, corsOrigin);
    }

    if (path === '/v1/files' && method === 'POST') {
      const body = await parseBody(req);
      const fileId = `file-${uuid()}`;
      const createdAt = Math.floor(Date.now() / 1000);
      fileStorage.set(fileId, { id: fileId, filename: body.filename || fileId, purpose: body.purpose || 'search', bytes: body.file?.length || 0, content: body.file, created_at: createdAt });
      return sendJson(res, 200, { id: fileId, object: 'file', bytes: body.file?.length || 0, created_at: createdAt, filename: body.filename || fileId, purpose: body.purpose || 'search', status: 'processed' }, corsOrigin);
    }

    // Moderations
    if (path === '/v1/moderations' && method === 'POST') {
      const body = await parseBody(req);
      const inputs = Array.isArray(body.input) ? body.input : [body.input];
      return sendJson(res, 200, { id: `modr-${uuid()}`, model: body.model || 'text-moderation-latest', results: inputs.map(() => ({ flagged: false, categories: { hate: false, violence: false }, category_scores: { hate: 0, violence: 0 } })) }, corsOrigin);
    }

    // Assistants
    if (path === '/v1/assistants' && method === 'GET') {
      const list = Array.from(assistants.values()).sort((a, b) => b.created_at - a.created_at);
      return sendJson(res, 200, { object: 'list', data: list.slice(0, 20), has_more: list.length > 20 }, corsOrigin);
    }

    if (path === '/v1/assistants' && method === 'POST') {
      const body = await parseBody(req);
      const assistantId = `asst_${uuid().replace(/-/g, '').substring(0, 24)}`;
      const created_at = Math.floor(Date.now() / 1000);
      const assistant = { id: assistantId, object: 'assistant', created_at, name: body.name, model: body.model, instructions: body.instructions, tools: body.tools || [], metadata: body.metadata || {} };
      assistants.set(assistantId, assistant);
      return sendJson(res, 200, assistant, corsOrigin);
    }

    // Threads
    if (path === '/v1/threads' && method === 'POST') {
      const body = await parseBody(req);
      const threadId = `thread_${uuid().replace(/-/g, '').substring(0, 24)}`;
      const created_at = Math.floor(Date.now() / 1000);
      const thread = { id: threadId, object: 'thread', created_at, metadata: body.metadata || {} };
      threads.set(threadId, thread);
      messages.set(threadId, []);
      return sendJson(res, 200, thread, corsOrigin);
    }

    // Batches
    if (path === '/v1/batches' && method === 'GET') {
      return sendJson(res, 200, { object: 'list', data: Array.from(batches.values()).slice(0, 20) }, corsOrigin);
    }

    if (path === '/v1/batches' && method === 'POST') {
      const body = await parseBody(req);
      const batchId = `batch_${uuid().replace(/-/g, '').substring(0, 24)}`;
      const created_at = Math.floor(Date.now() / 1000);
      const batch = { id: batchId, object: 'batch', endpoint: body.endpoint, input_file_id: body.input_file_id, status: 'validating', created_at, metadata: body.metadata || {} };
      batches.set(batchId, batch);
      return sendJson(res, 200, batch, corsOrigin);
    }

    // Vector Store
    if (path === '/v1/hana/tables' && method === 'GET') {
      return sendJson(res, 200, { object: 'list', data: Array.from(vectorTables.keys()), source: 'memory' }, corsOrigin);
    }

    if (path === '/v1/hana/vectors' && method === 'POST') {
      const body = await parseBody(req);
      if (!body.table_name) return sendError(res, 400, 'table_name is required', corsOrigin);
      const deployments = await getDeployments(config);
      const deployment = deployments.find(d => d.model.toLowerCase().includes('embed')) || deployments[0];
      if (!deployment) return sendError(res, 400, 'No embedding model available', corsOrigin);
      const result = await aicoreRequest(config, 'POST', `/v2/inference/deployments/${deployment.id}/embeddings`, { input: body.documents });
      const embeddings = (result.data || []).map(d => d.embedding || []);
      if (!vectorTables.has(body.table_name)) vectorTables.set(body.table_name, []);
      const table = vectorTables.get(body.table_name);
      body.documents.forEach((doc, i) => table.push({ id: body.ids?.[i] || `doc-${uuid()}`, content: doc, embedding: embeddings[i] }));
      return sendJson(res, 200, { status: 'stored', table_name: body.table_name, documents_stored: body.documents.length, model: deployment.id }, corsOrigin);
    }

    if (path === '/v1/hana/search' && method === 'POST') {
      const body = await parseBody(req);
      if (!body.vector_table) return sendError(res, 400, 'vector_table is required', corsOrigin);
      const table = vectorTables.get(body.vector_table);
      if (!table || table.length === 0) return sendJson(res, 200, { object: 'list', data: [] }, corsOrigin);
      const deployments = await getDeployments(config);
      const deployment = deployments.find(d => d.model.toLowerCase().includes('embed')) || deployments[0];
      const result = await aicoreRequest(config, 'POST', `/v2/inference/deployments/${deployment.id}/embeddings`, { input: [body.query] });
      const queryEmb = result.data?.[0]?.embedding || [];
      const scores = table.map((doc, i) => {
        let dot = 0, normA = 0, normB = 0;
        for (let j = 0; j < queryEmb.length; j++) { dot += queryEmb[j] * doc.embedding[j]; normA += queryEmb[j] * queryEmb[j]; normB += doc.embedding[j] * doc.embedding[j]; }
        return { document: i, score: dot / (Math.sqrt(normA) * Math.sqrt(normB)) || 0, text: doc.content };
      }).sort((a, b) => b.score - a.score).slice(0, body.max_rerank || 10);
      return sendJson(res, 200, { object: 'list', data: scores.map(s => ({ object: 'search_result', ...s })), model: deployment.id }, corsOrigin);
    }

    return sendError(res, 404, `Endpoint ${path} not found`, corsOrigin);
  } catch (error) {
    console.error('Error:', error);
    return sendError(res, 500, String(error), corsOrigin);
  }
}

// =============================================================================
// Server
// =============================================================================

const PORT = parseInt(process.env.PORT || process.argv.find(a => a.startsWith('--port='))?.split('=')[1] || '8500');

const server = http.createServer(handleRequest);

server.listen(PORT, () => {
  console.log(`
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║   SAP OpenAI-Compatible Server (OData Vocabularies)      ║
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

module.exports = { server, handleRequest };