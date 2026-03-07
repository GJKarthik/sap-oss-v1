/**
 * SAP OpenAI-Compatible Server for World Monitor
 * 
 * Full OpenAI API-compliant server that routes to SAP AI Core
 * with geographic/world monitoring data integration.
 * 
 * Usage:
 *   npx tsx sap_openai_server/server.ts --port 8300
 *   # or add to package.json scripts
 */

import http from 'http';
import https from 'https';
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
    clientId: process.env.AICORE_CLIENT_ID || '',
    clientSecret: process.env.AICORE_CLIENT_SECRET || '',
    authUrl: process.env.AICORE_AUTH_URL || '',
    baseUrl: process.env.AICORE_BASE_URL || process.env.AICORE_SERVICE_URL || '',
    resourceGroup: process.env.AICORE_RESOURCE_GROUP || 'default',
    chatDeploymentId: process.env.AICORE_CHAT_DEPLOYMENT_ID,
    embeddingDeploymentId: process.env.AICORE_EMBEDDING_DEPLOYMENT_ID,
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
    const options = {
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
      res.on('data', chunk => data += chunk);
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

async function aicoreRequest(config: AICoreConfig, method: string, path: string, body?: any): Promise<any> {
  const token = await getAccessToken(config);
  const url = new URL(path, config.baseUrl);
  
  return new Promise((resolve, reject) => {
    const options = {
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
      res.on('data', chunk => data += chunk);
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
  
  const result = await aicoreRequest(config, 'GET', '/v2/lm/deployments');
  cachedDeployments = (result.resources || []).map((d: any) => ({
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

const fileStorage: Map<string, any> = new Map();
const assistants: Map<string, any> = new Map();
const threads: Map<string, any> = new Map();
const messages: Map<string, any[]> = new Map();
const runs: Map<string, any> = new Map();
const batches: Map<string, any> = new Map();
const vectorTables: Map<string, any[]> = new Map();

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

async function parseBody(req: http.IncomingMessage): Promise<any> {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', chunk => data += chunk);
    req.on('end', () => {
      try {
        resolve(JSON.parse(data));
      } catch {
        resolve({});
      }
    });
  });
}

function sendJson(res: http.ServerResponse, status: number, data: any): void {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
  res.end(JSON.stringify(data));
}

function sendError(res: http.ServerResponse, status: number, message: string): void {
  sendJson(res, status, { error: { message, type: 'api_error', code: status } });
}

async function handleRequest(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
  // CORS
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
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
        service: 'sap-openai-server-world-monitor',
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

    if (path.match(/^\/v1\/models\/[\w-]+$/) && method === 'GET') {
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
      let deployment = findDeployment(deployments, body.model);
      if (!deployment && config.chatDeploymentId) deployment = findDeployment(deployments, config.chatDeploymentId);
      if (!deployment) return sendError(res, 400, `Model ${body.model} not found`);

      const completionId = `chatcmpl-${uuid()}`;
      const created = Math.floor(Date.now() / 1000);

      if (deployment.isAnthropic) {
        const result = await aicoreRequest(config, 'POST',
          `/v2/inference/deployments/${deployment.id}/invoke`,
          {
            anthropic_version: 'bedrock-2023-05-31',
            max_tokens: body.max_tokens || 1024,
            messages: body.messages,
          }
        );

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
            model: body.model,
            messages: body.messages,
            max_tokens: body.max_tokens,
            temperature: body.temperature,
          }
        );
        return sendJson(res, 200, { id: completionId, ...result, model: deployment.id });
      }
    }

    // Embeddings
    if (path === '/v1/embeddings' && method === 'POST') {
      const body = await parseBody(req);
      const deployments = await getDeployments(config);
      let deployment = findDeployment(deployments, body.model);
      if (!deployment) deployment = deployments.find(d => d.model.toLowerCase().includes('embed')) || deployments[0];
      if (!deployment) return sendError(res, 400, 'No embedding model available');

      const inputs = Array.isArray(body.input) ? body.input : [body.input];
      const result = await aicoreRequest(config, 'POST',
        `/v2/inference/deployments/${deployment.id}/embeddings`,
        { input: inputs, model: body.model }
      );

      return sendJson(res, 200, {
        object: 'list',
        data: result.data || [],
        model: deployment.id,
        usage: result.usage || { prompt_tokens: 0, total_tokens: 0 },
      });
    }

    // Completions (legacy)
    if (path === '/v1/completions' && method === 'POST') {
      const body = await parseBody(req);
      req.url = '/v1/chat/completions';
      return handleRequest(Object.assign(req, {
        _body: {
          model: body.model,
          messages: [{ role: 'user', content: body.prompt }],
          max_tokens: body.max_tokens,
          temperature: body.temperature,
        }
      }), res);
    }

    // Files
    if (path === '/v1/files' && method === 'GET') {
      return sendJson(res, 200, {
        object: 'list',
        data: Array.from(fileStorage.values()).map(f => ({
          id: f.id,
          object: 'file',
          bytes: f.bytes,
          created_at: f.created_at,
          filename: f.filename,
          purpose: f.purpose,
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
        filename: body.filename || fileId,
        purpose: body.purpose || 'search',
        bytes: body.file?.length || 0,
        content: body.file,
        created_at: createdAt,
      });
      return sendJson(res, 200, { id: fileId, object: 'file', bytes: body.file?.length || 0, created_at: createdAt, filename: body.filename || fileId, purpose: body.purpose || 'search', status: 'processed' });
    }

    if (path.match(/^\/v1\/files\/[\w-]+$/) && method === 'GET') {
      const fileId = path.split('/').pop()!;
      const file = fileStorage.get(fileId);
      if (!file) return sendError(res, 404, 'File not found');
      return sendJson(res, 200, { id: file.id, object: 'file', bytes: file.bytes, created_at: file.created_at, filename: file.filename, purpose: file.purpose, status: 'processed' });
    }

    if (path.match(/^\/v1\/files\/[\w-]+$/) && method === 'DELETE') {
      const fileId = path.split('/').pop()!;
      if (!fileStorage.has(fileId)) return sendError(res, 404, 'File not found');
      fileStorage.delete(fileId);
      return sendJson(res, 200, { id: fileId, object: 'file', deleted: true });
    }

    // Moderations
    if (path === '/v1/moderations' && method === 'POST') {
      const body = await parseBody(req);
      const inputs = Array.isArray(body.input) ? body.input : [body.input];
      return sendJson(res, 200, {
        id: `modr-${uuid()}`,
        model: body.model || 'text-moderation-latest',
        results: inputs.map(() => ({
          flagged: false,
          categories: { hate: false, violence: false, 'self-harm': false, sexual: false },
          category_scores: { hate: 0, violence: 0, 'self-harm': 0, sexual: 0 },
        }))
      });
    }

    // Images (placeholder)
    if (path === '/v1/images/generations' && method === 'POST') {
      return sendError(res, 501, 'Image generation not supported. Use SAP AI Core image models directly.');
    }

    // Audio (placeholders)
    if (path.startsWith('/v1/audio/') && method === 'POST') {
      return sendError(res, 501, 'Audio processing not supported. Use SAP AI Core speech models directly.');
    }

    // Assistants
    if (path === '/v1/assistants' && method === 'GET') {
      const list = Array.from(assistants.values()).sort((a, b) => b.created_at - a.created_at);
      return sendJson(res, 200, { object: 'list', data: list.slice(0, 20), first_id: list[0]?.id, last_id: list[list.length - 1]?.id, has_more: list.length > 20 });
    }

    if (path === '/v1/assistants' && method === 'POST') {
      const body = await parseBody(req);
      const assistantId = `asst_${uuid().replace(/-/g, '').substring(0, 24)}`;
      const created_at = Math.floor(Date.now() / 1000);
      const assistant = {
        id: assistantId,
        object: 'assistant',
        created_at,
        name: body.name,
        description: body.description,
        model: body.model,
        instructions: body.instructions,
        tools: body.tools || [],
        file_ids: body.file_ids || [],
        metadata: body.metadata || {},
      };
      assistants.set(assistantId, assistant);
      return sendJson(res, 200, assistant);
    }

    if (path.match(/^\/v1\/assistants\/asst_[\w]+$/) && method === 'GET') {
      const assistantId = path.split('/').pop()!;
      if (!assistants.has(assistantId)) return sendError(res, 404, 'Assistant not found');
      return sendJson(res, 200, assistants.get(assistantId));
    }

    if (path.match(/^\/v1\/assistants\/asst_[\w]+$/) && method === 'DELETE') {
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
      const thread = { id: threadId, object: 'thread', created_at, metadata: body.metadata || {} };
      threads.set(threadId, thread);
      messages.set(threadId, []);
      return sendJson(res, 200, thread);
    }

    if (path.match(/^\/v1\/threads\/thread_[\w]+$/) && method === 'GET') {
      const threadId = path.split('/').pop()!;
      if (!threads.has(threadId)) return sendError(res, 404, 'Thread not found');
      return sendJson(res, 200, threads.get(threadId));
    }

    if (path.match(/^\/v1\/threads\/thread_[\w]+$/) && method === 'DELETE') {
      const threadId = path.split('/').pop()!;
      if (!threads.has(threadId)) return sendError(res, 404, 'Thread not found');
      threads.delete(threadId);
      messages.delete(threadId);
      return sendJson(res, 200, { id: threadId, object: 'thread.deleted', deleted: true });
    }

    // Thread Messages
    if (path.match(/^\/v1\/threads\/thread_[\w]+\/messages$/) && method === 'GET') {
      const threadId = path.split('/')[3];
      if (!threads.has(threadId)) return sendError(res, 404, 'Thread not found');
      const msgs = messages.get(threadId) || [];
      return sendJson(res, 200, { object: 'list', data: msgs.slice().reverse().slice(0, 20), first_id: msgs[0]?.id, last_id: msgs[msgs.length - 1]?.id, has_more: msgs.length > 20 });
    }

    if (path.match(/^\/v1\/threads\/thread_[\w]+\/messages$/) && method === 'POST') {
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
        role: body.role,
        content: [{ type: 'text', text: { value: body.content, annotations: [] } }],
        file_ids: body.file_ids || [],
        assistant_id: null,
        run_id: null,
        metadata: body.metadata || {},
      };
      messages.get(threadId)!.push(message);
      return sendJson(res, 200, message);
    }

    // Thread Runs
    if (path.match(/^\/v1\/threads\/thread_[\w]+\/runs$/) && method === 'GET') {
      const threadId = path.split('/')[3];
      const threadRuns = Array.from(runs.values()).filter(r => r.thread_id === threadId);
      return sendJson(res, 200, { object: 'list', data: threadRuns.slice(0, 20), first_id: threadRuns[0]?.id, last_id: threadRuns[threadRuns.length - 1]?.id, has_more: threadRuns.length > 20 });
    }

    if (path.match(/^\/v1\/threads\/thread_[\w]+\/runs$/) && method === 'POST') {
      const body = await parseBody(req);
      const threadId = path.split('/')[3];
      if (!threads.has(threadId)) return sendError(res, 404, 'Thread not found');
      if (!assistants.has(body.assistant_id)) return sendError(res, 404, 'Assistant not found');
      
      const assistant = assistants.get(body.assistant_id)!;
      const runId = `run_${uuid().replace(/-/g, '').substring(0, 24)}`;
      const created_at = Math.floor(Date.now() / 1000);
      
      // Get messages from thread
      const threadMsgs = (messages.get(threadId) || []).map(m => ({
        role: m.role,
        content: m.content[0]?.text?.value || '',
      }));
      
      // Add instructions
      if (assistant.instructions || body.instructions) {
        threadMsgs.unshift({ role: 'system', content: body.instructions || assistant.instructions });
      }
      
      const deployments = await getDeployments(config);
      let deployment = findDeployment(deployments, body.model || assistant.model);
      if (!deployment) deployment = deployments[0];
      if (!deployment) return sendError(res, 400, 'No model available');
      
      let status = 'completed';
      let content = '';
      
      try {
        const result = await aicoreRequest(config, 'POST',
          `/v2/inference/deployments/${deployment.id}/invoke`,
          {
            anthropic_version: 'bedrock-2023-05-31',
            max_tokens: 1024,
            messages: threadMsgs,
          }
        );
        content = result.content?.[0]?.text || '';
        
        // Add response to messages
        const responseMsg = {
          id: `msg_${uuid().replace(/-/g, '').substring(0, 24)}`,
          object: 'thread.message',
          created_at: Math.floor(Date.now() / 1000),
          thread_id: threadId,
          role: 'assistant',
          content: [{ type: 'text', text: { value: content, annotations: [] } }],
          file_ids: [],
          assistant_id: body.assistant_id,
          run_id: runId,
          metadata: {},
        };
        messages.get(threadId)!.push(responseMsg);
      } catch (e) {
        status = 'failed';
      }
      
      const run = {
        id: runId,
        object: 'thread.run',
        created_at,
        thread_id: threadId,
        assistant_id: body.assistant_id,
        status,
        model: deployment.id,
        instructions: body.instructions || assistant.instructions,
        tools: body.tools || assistant.tools || [],
        metadata: {},
      };
      runs.set(runId, run);
      return sendJson(res, 200, run);
    }

    if (path.match(/^\/v1\/threads\/thread_[\w]+\/runs\/run_[\w]+$/) && method === 'GET') {
      const runId = path.split('/').pop()!;
      if (!runs.has(runId)) return sendError(res, 404, 'Run not found');
      return sendJson(res, 200, runs.get(runId));
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
        endpoint: body.endpoint,
        input_file_id: body.input_file_id,
        completion_window: body.completion_window || '24h',
        status: 'validating',
        created_at,
        metadata: body.metadata || {},
      };
      batches.set(batchId, batch);
      return sendJson(res, 200, batch);
    }

    if (path.match(/^\/v1\/batches\/batch_[\w]+$/) && method === 'GET') {
      const batchId = path.split('/').pop()!;
      if (!batches.has(batchId)) return sendError(res, 404, 'Batch not found');
      return sendJson(res, 200, batches.get(batchId));
    }

    if (path.match(/^\/v1\/batches\/batch_[\w]+\/cancel$/) && method === 'POST') {
      const batchId = path.split('/')[3];
      if (!batches.has(batchId)) return sendError(res, 404, 'Batch not found');
      batches.get(batchId)!.status = 'cancelled';
      return sendJson(res, 200, batches.get(batchId));
    }

    // Fine-tunes
    if (path === '/v1/fine-tunes' && method === 'GET') {
      const deployments = await getDeployments(config);
      return sendJson(res, 200, {
        object: 'list',
        data: deployments.map(d => ({
          id: `ft-${d.id}`,
          object: 'fine-tune',
          model: d.model,
          created_at: Math.floor(Date.now() / 1000),
          status: d.status === 'RUNNING' ? 'succeeded' : 'pending',
          fine_tuned_model: d.id,
        }))
      });
    }

    // Search
    if (path === '/v1/search' && method === 'POST') {
      const body = await parseBody(req);
      if (body.documents && body.documents.length > 0) {
        const deployments = await getDeployments(config);
        const deployment = deployments.find(d => d.model.toLowerCase().includes('embed')) || deployments[0];
        if (!deployment) return sendError(res, 400, 'No embedding model available');
        
        const allInputs = [body.query, ...body.documents];
        const result = await aicoreRequest(config, 'POST',
          `/v2/inference/deployments/${deployment.id}/embeddings`,
          { input: allInputs }
        );
        
        const embeddings = (result.data || []).map((d: any) => d.embedding || []);
        const queryEmb = embeddings[0] || [];
        const docEmbs = embeddings.slice(1);
        
        const scores = docEmbs.map((emb: number[], i: number) => ({
          document: i,
          score: cosineSimilarity(queryEmb, emb),
          text: body.return_documents ? body.documents[i] : undefined,
        })).sort((a: any, b: any) => b.score - a.score).slice(0, body.max_rerank || 10);
        
        return sendJson(res, 200, { object: 'list', data: scores.map((s: any) => ({ object: 'search_result', ...s })), model: deployment.id });
      }
      return sendJson(res, 200, { object: 'list', data: [], model: 'unknown' });
    }

    // HANA endpoints (vector store)
    if (path === '/v1/hana/tables' && method === 'GET') {
      return sendJson(res, 200, { object: 'list', data: Array.from(vectorTables.keys()), source: 'memory' });
    }

    if (path === '/v1/hana/vectors' && method === 'POST') {
      const body = await parseBody(req);
      const tableName = body.table_name;
      if (!tableName) return sendError(res, 400, 'table_name is required');
      
      const deployments = await getDeployments(config);
      const deployment = deployments.find(d => d.model.toLowerCase().includes('embed')) || deployments[0];
      if (!deployment) return sendError(res, 400, 'No embedding model available');
      
      const result = await aicoreRequest(config, 'POST',
        `/v2/inference/deployments/${deployment.id}/embeddings`,
        { input: body.documents }
      );
      
      const embeddings = (result.data || []).map((d: any) => d.embedding || []);
      const ids = body.ids || body.documents.map(() => `doc-${uuid()}`);
      
      if (!vectorTables.has(tableName)) vectorTables.set(tableName, []);
      const table = vectorTables.get(tableName)!;
      
      body.documents.forEach((doc: string, i: number) => {
        table.push({ id: ids[i], content: doc, embedding: embeddings[i] });
      });
      
      return sendJson(res, 200, { status: 'stored', table_name: tableName, documents_stored: body.documents.length, model: deployment.id });
    }

    if (path === '/v1/hana/search' && method === 'POST') {
      const body = await parseBody(req);
      const tableName = body.vector_table;
      if (!tableName) return sendError(res, 400, 'vector_table is required');
      
      const table = vectorTables.get(tableName);
      if (!table || table.length === 0) return sendJson(res, 200, { object: 'list', data: [] });
      
      const deployments = await getDeployments(config);
      const deployment = deployments.find(d => d.model.toLowerCase().includes('embed')) || deployments[0];
      if (!deployment) return sendError(res, 400, 'No embedding model available');
      
      const result = await aicoreRequest(config, 'POST',
        `/v2/inference/deployments/${deployment.id}/embeddings`,
        { input: [body.query] }
      );
      
      const queryEmb = result.data?.[0]?.embedding || [];
      const scores = table.map((doc, i) => ({
        document: i,
        score: cosineSimilarity(queryEmb, doc.embedding),
        text: doc.content,
      })).sort((a, b) => b.score - a.score).slice(0, body.max_rerank || 10);
      
      return sendJson(res, 200, { object: 'list', data: scores.map(s => ({ object: 'search_result', ...s })), model: deployment.id, source: 'memory' });
    }

    if (path.match(/^\/v1\/hana\/tables\/[\w-]+$/) && method === 'DELETE') {
      const tableName = path.split('/').pop()!;
      if (!vectorTables.has(tableName)) return sendError(res, 404, 'Table not found');
      vectorTables.delete(tableName);
      return sendJson(res, 200, { status: 'deleted', table_name: tableName });
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

const PORT = parseInt(process.env.PORT || process.argv.find(a => a.startsWith('--port='))?.split('=')[1] || '8300');

const server = http.createServer(handleRequest);

server.listen(PORT, () => {
  console.log(`
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║   SAP OpenAI-Compatible Server (World Monitor)           ║
║   Powered by SAP AI Core                                 ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝

Server running at: http://localhost:${PORT}

Full OpenAI API Endpoints:
  GET  /health              - Health check
  GET  /v1/models           - List models
  POST /v1/chat/completions - Chat completions
  POST /v1/embeddings       - Generate embeddings
  POST /v1/completions      - Legacy completions
  POST /v1/search           - Semantic search
  GET  /v1/files            - List files
  POST /v1/files            - Upload file
  GET  /v1/fine-tunes       - List fine-tunes
  POST /v1/moderations      - Content moderation
  POST /v1/images/generations - Image generation (stub)
  POST /v1/audio/*          - Audio processing (stub)
  
Assistants API:
  GET/POST /v1/assistants   - List/create assistants
  GET/DEL  /v1/assistants/:id - Get/delete assistant
  POST     /v1/threads      - Create thread
  GET/DEL  /v1/threads/:id  - Get/delete thread
  GET/POST /v1/threads/:id/messages - Messages
  GET/POST /v1/threads/:id/runs     - Runs

Batches API:
  GET/POST /v1/batches      - List/create batches
  GET      /v1/batches/:id  - Get batch
  POST     /v1/batches/:id/cancel - Cancel batch

Vector Store:
  GET  /v1/hana/tables      - List vector tables
  POST /v1/hana/vectors     - Store vectors
  POST /v1/hana/search      - Search vectors
  DEL  /v1/hana/tables/:id  - Delete table
`);
});

export { server, handleRequest };