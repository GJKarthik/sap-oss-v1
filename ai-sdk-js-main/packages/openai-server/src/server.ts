/**
 * OpenAI-Compatible HTTP Server
 * 
 * Provides full OpenAI API compatibility while routing to SAP AI Core.
 * Supports both OpenAI and Anthropic model formats.
 */

import express, { Express, Request, Response, NextFunction } from 'express';
import cors from 'cors';
import { v4 as uuidv4 } from 'uuid';
import * as https from 'https';

// =============================================================================
// Types
// =============================================================================

interface AICoreConfig {
  clientId: string;
  clientSecret: string;
  authUrl: string;
  baseUrl: string;
  resourceGroup: string;
}

interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

interface ChatCompletionRequest {
  model: string;
  messages: ChatMessage[];
  temperature?: number;
  max_tokens?: number;
  stream?: boolean;
  top_p?: number;
  frequency_penalty?: number;
  presence_penalty?: number;
  stop?: string | string[];
}

interface EmbeddingRequest {
  model: string;
  input: string | string[];
  encoding_format?: 'float' | 'base64';
}

interface Deployment {
  id: string;
  model: string;
  status: string;
  isAnthropic: boolean;
}

// =============================================================================
// AI Core Client
// =============================================================================

let cachedToken: { token: string; expiresAt: number } | null = null;
let cachedDeployments: Deployment[] = [];

async function getAccessToken(config: AICoreConfig): Promise<string> {
  if (cachedToken && Date.now() < cachedToken.expiresAt) {
    return cachedToken.token;
  }

  const authUrl = new URL(config.authUrl);
  const auth = Buffer.from(`${config.clientId}:${config.clientSecret}`).toString('base64');
  const postData = 'grant_type=client_credentials';

  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: authUrl.hostname,
      port: 443,
      path: authUrl.pathname,
      method: 'POST',
      headers: {
        'Authorization': `Basic ${auth}`,
        'Content-Type': 'application/x-www-form-urlencoded',
        'Content-Length': postData.length,
      },
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        if (res.statusCode === 200) {
          const json = JSON.parse(data);
          cachedToken = {
            token: json.access_token,
            expiresAt: Date.now() + (json.expires_in - 60) * 1000,
          };
          resolve(json.access_token);
        } else {
          reject(new Error(`Auth failed: ${res.statusCode} - ${data}`));
        }
      });
    });
    req.on('error', reject);
    req.write(postData);
    req.end();
  });
}

async function aiCoreRequest<T>(
  config: AICoreConfig,
  method: string,
  path: string,
  body?: unknown
): Promise<T> {
  const token = await getAccessToken(config);
  const baseUrl = new URL(config.baseUrl);

  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: baseUrl.hostname,
      port: 443,
      path: path,
      method: method,
      headers: {
        'Authorization': `Bearer ${token}`,
        'AI-Resource-Group': config.resourceGroup,
        'Content-Type': 'application/json',
      },
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
          resolve(JSON.parse(data));
        } else {
          reject(new Error(`${res.statusCode}: ${data}`));
        }
      });
    });
    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

async function streamAICoreRequest(
  config: AICoreConfig,
  path: string,
  body: unknown,
  res: Response
): Promise<void> {
  const token = await getAccessToken(config);
  const baseUrl = new URL(config.baseUrl);

  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: baseUrl.hostname,
      port: 443,
      path: path,
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${token}`,
        'AI-Resource-Group': config.resourceGroup,
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
      },
    }, (aiRes) => {
      if (aiRes.statusCode && aiRes.statusCode >= 400) {
        let data = '';
        aiRes.on('data', chunk => data += chunk);
        aiRes.on('end', () => reject(new Error(`${aiRes.statusCode}: ${data}`)));
        return;
      }

      // Stream the response
      aiRes.on('data', chunk => res.write(chunk));
      aiRes.on('end', () => {
        res.end();
        resolve();
      });
    });
    req.on('error', reject);
    req.write(JSON.stringify(body));
    req.end();
  });
}

async function getDeployments(config: AICoreConfig): Promise<Deployment[]> {
  if (cachedDeployments.length > 0) {
    return cachedDeployments;
  }

  const result = await aiCoreRequest<{ resources: any[] }>(config, 'GET', '/v2/lm/deployments');
  
  cachedDeployments = (result.resources || []).map(d => ({
    id: d.id,
    model: d.details?.resources?.backend_details?.model?.name || 'unknown',
    status: d.status || 'unknown',
    isAnthropic: (d.details?.resources?.backend_details?.model?.name || '').includes('anthropic'),
  }));

  return cachedDeployments;
}

function findDeployment(deployments: Deployment[], modelId: string): Deployment | undefined {
  // Try exact match first
  let deployment = deployments.find(d => d.id === modelId);
  if (deployment) return deployment;

  // Try model name match
  deployment = deployments.find(d => d.model === modelId || d.model.includes(modelId) || modelId.includes(d.model));
  if (deployment) return deployment;

  // Try partial match
  deployment = deployments.find(d => 
    modelId.toLowerCase().includes(d.id.substring(0, 8)) ||
    d.id.toLowerCase().includes(modelId.substring(0, 8))
  );
  
  return deployment;
}

// =============================================================================
// Server Factory
// =============================================================================

export interface ServerOptions {
  port?: number;
  config?: AICoreConfig;
  defaultChatModel?: string;
  defaultEmbeddingModel?: string;
  apiKey?: string;
}

export function createServer(options: ServerOptions = {}): Express {
  const app = express();
  
  // Middleware
  app.use(cors());
  app.use(express.json({ limit: '50mb' }));

  // Get config from env or options
  const config: AICoreConfig = options.config || {
    clientId: process.env.AICORE_CLIENT_ID || '',
    clientSecret: process.env.AICORE_CLIENT_SECRET || '',
    authUrl: process.env.AICORE_AUTH_URL || '',
    baseUrl: process.env.AICORE_BASE_URL || process.env.AICORE_SERVICE_URL || '',
    resourceGroup: process.env.AICORE_RESOURCE_GROUP || 'default',
  };

  const defaultChatModel = options.defaultChatModel || process.env.AICORE_CHAT_DEPLOYMENT_ID || '';
  const apiKey = options.apiKey || process.env.OPENAI_API_KEY || '';

  // ==========================================================================
  // Auth Middleware
  // ==========================================================================
  
  const authMiddleware = (req: Request, res: Response, next: NextFunction) => {
    if (apiKey) {
      const authHeader = req.headers.authorization;
      if (!authHeader || !authHeader.startsWith('Bearer ')) {
        return res.status(401).json({ error: { message: 'Missing API key', type: 'invalid_request_error' } });
      }
      const providedKey = authHeader.substring(7);
      if (providedKey !== apiKey) {
        return res.status(401).json({ error: { message: 'Invalid API key', type: 'invalid_request_error' } });
      }
    }
    next();
  };

  // ==========================================================================
  // Routes
  // ==========================================================================

  // Health check
  app.get('/health', (req, res) => {
    res.json({ status: 'healthy', service: 'sap-openai-server' });
  });

  // List models (OpenAI compatible)
  app.get('/v1/models', authMiddleware, async (req, res) => {
    try {
      const deployments = await getDeployments(config);
      
      res.json({
        object: 'list',
        data: deployments.map(d => ({
          id: d.id,
          object: 'model',
          created: Math.floor(Date.now() / 1000),
          owned_by: d.isAnthropic ? 'anthropic' : 'openai',
          permission: [],
          root: d.model,
          parent: null,
        })),
      });
    } catch (error: any) {
      res.status(500).json({ error: { message: error.message, type: 'server_error' } });
    }
  });

  // Get model details
  app.get('/v1/models/:id', authMiddleware, async (req, res) => {
    try {
      const deployments = await getDeployments(config);
      const deployment = findDeployment(deployments, req.params.id);
      
      if (!deployment) {
        return res.status(404).json({ error: { message: 'Model not found', type: 'invalid_request_error' } });
      }

      res.json({
        id: deployment.id,
        object: 'model',
        created: Math.floor(Date.now() / 1000),
        owned_by: deployment.isAnthropic ? 'anthropic' : 'openai',
        permission: [],
        root: deployment.model,
        parent: null,
      });
    } catch (error: any) {
      res.status(500).json({ error: { message: error.message, type: 'server_error' } });
    }
  });

  // Chat completions (OpenAI compatible)
  app.post('/v1/chat/completions', authMiddleware, async (req, res) => {
    try {
      const body: ChatCompletionRequest = req.body;
      const deployments = await getDeployments(config);
      
      // Find deployment
      let deployment = findDeployment(deployments, body.model);
      if (!deployment && defaultChatModel) {
        deployment = findDeployment(deployments, defaultChatModel);
      }
      if (!deployment) {
        return res.status(400).json({ 
          error: { message: `Model ${body.model} not found`, type: 'invalid_request_error' } 
        });
      }

      const completionId = `chatcmpl-${uuidv4()}`;
      const created = Math.floor(Date.now() / 1000);

      if (deployment.isAnthropic) {
        // Anthropic Claude format
        if (body.stream) {
          res.setHeader('Content-Type', 'text/event-stream');
          res.setHeader('Cache-Control', 'no-cache');
          res.setHeader('Connection', 'keep-alive');

          const result = await aiCoreRequest<any>(config, 'POST', 
            `/v2/inference/deployments/${deployment.id}/invoke`, {
              anthropic_version: "bedrock-2023-05-31",
              max_tokens: body.max_tokens || 1024,
              messages: body.messages,
              stream: false, // Anthropic via AI Core may not support streaming
            }
          );

          const content = result.content?.[0]?.text || '';
          
          // Simulate streaming for Anthropic
          const words = content.split(' ');
          
          // Send initial chunk
          res.write(`data: ${JSON.stringify({
            id: completionId,
            object: 'chat.completion.chunk',
            created,
            model: deployment.id,
            choices: [{ index: 0, delta: { role: 'assistant', content: '' }, finish_reason: null }],
          })}\n\n`);

          // Send content chunks
          for (let i = 0; i < words.length; i++) {
            const word = i === 0 ? words[i] : ' ' + words[i];
            res.write(`data: ${JSON.stringify({
              id: completionId,
              object: 'chat.completion.chunk',
              created,
              model: deployment.id,
              choices: [{ index: 0, delta: { content: word }, finish_reason: null }],
            })}\n\n`);
          }

          // Send final chunk
          res.write(`data: ${JSON.stringify({
            id: completionId,
            object: 'chat.completion.chunk',
            created,
            model: deployment.id,
            choices: [{ index: 0, delta: {}, finish_reason: 'stop' }],
          })}\n\n`);

          res.write('data: [DONE]\n\n');
          res.end();
        } else {
          const result = await aiCoreRequest<any>(config, 'POST', 
            `/v2/inference/deployments/${deployment.id}/invoke`, {
              anthropic_version: "bedrock-2023-05-31",
              max_tokens: body.max_tokens || 1024,
              messages: body.messages,
            }
          );

          const content = result.content?.[0]?.text || '';
          const inputTokens = result.usage?.input_tokens || 0;
          const outputTokens = result.usage?.output_tokens || 0;

          res.json({
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
        }
      } else {
        // OpenAI format
        if (body.stream) {
          res.setHeader('Content-Type', 'text/event-stream');
          res.setHeader('Cache-Control', 'no-cache');
          res.setHeader('Connection', 'keep-alive');

          await streamAICoreRequest(config, 
            `/v2/inference/deployments/${deployment.id}/chat/completions`,
            { ...body, stream: true },
            res
          );
        } else {
          const result = await aiCoreRequest<any>(config, 'POST', 
            `/v2/inference/deployments/${deployment.id}/chat/completions`, body
          );
          
          res.json({
            id: completionId,
            ...result,
            model: deployment.id,
          });
        }
      }
    } catch (error: any) {
      console.error('Chat completion error:', error);
      res.status(500).json({ error: { message: error.message, type: 'server_error' } });
    }
  });

  // Embeddings (OpenAI compatible)
  app.post('/v1/embeddings', authMiddleware, async (req, res) => {
    try {
      const body: EmbeddingRequest = req.body;
      const deployments = await getDeployments(config);
      
      // Find embedding deployment
      let deployment = findDeployment(deployments, body.model);
      if (!deployment) {
        // Try to find any embedding-capable deployment
        deployment = deployments.find(d => 
          d.model.includes('embed') || d.model.includes('ada')
        );
      }
      
      if (!deployment) {
        return res.status(400).json({ 
          error: { message: `Embedding model ${body.model} not found`, type: 'invalid_request_error' } 
        });
      }

      const inputs = Array.isArray(body.input) ? body.input : [body.input];
      
      const result = await aiCoreRequest<any>(config, 'POST', 
        `/v2/inference/deployments/${deployment.id}/embeddings`, {
          input: inputs,
          model: body.model,
        }
      );

      res.json({
        object: 'list',
        data: result.data || [],
        model: deployment.id,
        usage: result.usage || { prompt_tokens: 0, total_tokens: 0 },
      });
    } catch (error: any) {
      console.error('Embeddings error:', error);
      res.status(500).json({ error: { message: error.message, type: 'server_error' } });
    }
  });

  // Legacy completions endpoint
  app.post('/v1/completions', authMiddleware, async (req, res) => {
    // Convert to chat format
    const chatReq: ChatCompletionRequest = {
      model: req.body.model,
      messages: [{ role: 'user', content: req.body.prompt || '' }],
      max_tokens: req.body.max_tokens,
      temperature: req.body.temperature,
      stream: req.body.stream,
    };

    req.body = chatReq;
    // Forward to chat completions
    return res.redirect(307, '/v1/chat/completions');
  });

  // ==========================================================================
  // OpenAI-Compliant Additional Endpoints
  // ==========================================================================

  // In-memory storage for files (in production, use database/Elasticsearch)
  const fileStorage: Map<string, { id: string; filename: string; purpose: string; bytes: number; content: string; embedding?: number[]; createdAt: number }> = new Map();

  // Search endpoint (OpenAI-compliant)
  app.post('/v1/search', authMiddleware, async (req, res) => {
    try {
      const { query, documents, model, max_rerank, return_documents } = req.body;
      
      if (!query) {
        return res.status(400).json({ 
          error: { message: 'query is required', type: 'invalid_request_error' } 
        });
      }

      const deployments = await getDeployments(config);
      
      // Find embedding deployment
      let deployment = model ? findDeployment(deployments, model) : undefined;
      if (!deployment) {
        deployment = deployments.find(d => d.model.includes('embed')) || deployments[0];
      }

      if (!deployment) {
        return res.status(400).json({ 
          error: { message: 'No model available', type: 'invalid_request_error' } 
        });
      }

      // If documents are provided, search within them
      if (documents && documents.length > 0) {
        // Generate embeddings for query and documents
        const allInputs = [query, ...documents];
        
        const result = await aiCoreRequest<any>(config, 'POST', 
          `/v2/inference/deployments/${deployment.id}/embeddings`, {
            input: allInputs,
          }
        );

        const embeddings = result.data?.map((d: any) => d.embedding) || [];
        const queryEmbedding = embeddings[0] || [];
        const docEmbeddings = embeddings.slice(1);

        // Calculate cosine similarity
        const cosineSimilarity = (a: number[], b: number[]) => {
          if (a.length !== b.length) return 0;
          let dotProduct = 0, normA = 0, normB = 0;
          for (let i = 0; i < a.length; i++) {
            dotProduct += a[i] * b[i];
            normA += a[i] * a[i];
            normB += b[i] * b[i];
          }
          return dotProduct / (Math.sqrt(normA) * Math.sqrt(normB));
        };

        // Score documents
        const scores = docEmbeddings.map((emb: number[], i: number) => ({
          document: i,
          score: cosineSimilarity(queryEmbedding, emb),
          text: return_documents !== false ? documents[i] : undefined,
        }));

        // Sort by score and limit
        scores.sort((a: any, b: any) => b.score - a.score);
        const topResults = scores.slice(0, max_rerank || 10);

        res.json({
          object: 'list',
          data: topResults.map((r: any, i: number) => ({
            object: 'search_result',
            document: r.document,
            score: r.score,
            text: r.text,
          })),
          model: deployment.id,
        });
      } else {
        // Search in stored files
        const storedFiles = Array.from(fileStorage.values()).filter(f => f.embedding);
        
        if (storedFiles.length === 0) {
          return res.json({
            object: 'list',
            data: [],
            model: deployment.id,
          });
        }

        // Generate query embedding
        const result = await aiCoreRequest<any>(config, 'POST', 
          `/v2/inference/deployments/${deployment.id}/embeddings`, {
            input: [query],
          }
        );

        const queryEmbedding = result.data?.[0]?.embedding || [];
        
        // Calculate similarity with stored files
        const cosineSimilarity = (a: number[], b: number[]) => {
          if (a.length !== b.length) return 0;
          let dotProduct = 0, normA = 0, normB = 0;
          for (let i = 0; i < a.length; i++) {
            dotProduct += a[i] * b[i];
            normA += a[i] * a[i];
            normB += b[i] * b[i];
          }
          return dotProduct / (Math.sqrt(normA) * Math.sqrt(normB));
        };

        const scores = storedFiles.map((f, i) => ({
          document: i,
          score: cosineSimilarity(queryEmbedding, f.embedding!),
          text: return_documents !== false ? f.content : undefined,
          file_id: f.id,
        }));

        scores.sort((a, b) => b.score - a.score);
        const topResults = scores.slice(0, max_rerank || 10);

        res.json({
          object: 'list',
          data: topResults.map((r, i) => ({
            object: 'search_result',
            document: r.document,
            score: r.score,
            text: r.text,
            file_id: r.file_id,
          })),
          model: deployment.id,
        });
      }
    } catch (error: any) {
      console.error('Search error:', error);
      res.status(500).json({ error: { message: error.message, type: 'server_error' } });
    }
  });

  // Files endpoints (OpenAI-compliant)
  app.post('/v1/files', authMiddleware, async (req, res) => {
    try {
      const { file, purpose, filename } = req.body;
      
      if (!file) {
        return res.status(400).json({ 
          error: { message: 'file content is required', type: 'invalid_request_error' } 
        });
      }

      const fileId = `file-${uuidv4()}`;
      const createdAt = Math.floor(Date.now() / 1000);
      const actualFilename = filename || fileId;

      // Try to generate embedding for the file content
      let embedding: number[] | undefined;
      try {
        const deployments = await getDeployments(config);
        const embeddingDeployment = deployments.find(d => d.model.includes('embed')) || deployments[0];
        
        if (embeddingDeployment) {
          const result = await aiCoreRequest<any>(config, 'POST', 
            `/v2/inference/deployments/${embeddingDeployment.id}/embeddings`, {
              input: [file],
            }
          );
          embedding = result.data?.[0]?.embedding;
        }
      } catch (e) {
        // Embedding generation failed, continue without it
      }

      // Store the file
      fileStorage.set(fileId, {
        id: fileId,
        filename: actualFilename,
        purpose: purpose || 'search',
        bytes: file.length,
        content: file,
        embedding,
        createdAt,
      });

      res.json({
        id: fileId,
        object: 'file',
        bytes: file.length,
        created_at: createdAt,
        filename: actualFilename,
        purpose: purpose || 'search',
        status: 'processed',
      });
    } catch (error: any) {
      console.error('File upload error:', error);
      res.status(500).json({ error: { message: error.message, type: 'server_error' } });
    }
  });

  app.get('/v1/files', authMiddleware, (req, res) => {
    const files = Array.from(fileStorage.values()).map(f => ({
      id: f.id,
      object: 'file',
      bytes: f.bytes,
      created_at: f.createdAt,
      filename: f.filename,
      purpose: f.purpose,
      status: 'processed',
    }));

    res.json({
      object: 'list',
      data: files,
    });
  });

  app.get('/v1/files/:file_id', authMiddleware, (req, res) => {
    const file = fileStorage.get(req.params.file_id);
    
    if (!file) {
      return res.status(404).json({ 
        error: { message: 'File not found', type: 'invalid_request_error' } 
      });
    }

    res.json({
      id: file.id,
      object: 'file',
      bytes: file.bytes,
      created_at: file.createdAt,
      filename: file.filename,
      purpose: file.purpose,
      status: 'processed',
    });
  });

  app.delete('/v1/files/:file_id', authMiddleware, (req, res) => {
    const file = fileStorage.get(req.params.file_id);
    
    if (!file) {
      return res.status(404).json({ 
        error: { message: 'File not found', type: 'invalid_request_error' } 
      });
    }

    fileStorage.delete(req.params.file_id);

    res.json({
      id: req.params.file_id,
      object: 'file',
      deleted: true,
    });
  });

  app.get('/v1/files/:file_id/content', authMiddleware, (req, res) => {
    const file = fileStorage.get(req.params.file_id);
    
    if (!file) {
      return res.status(404).json({ 
        error: { message: 'File not found', type: 'invalid_request_error' } 
      });
    }

    res.type('text/plain').send(file.content);
  });

  // Fine-tunes endpoint (OpenAI-compliant - placeholder)
  app.get('/v1/fine-tunes', authMiddleware, async (req, res) => {
    try {
      const deployments = await getDeployments(config);
      
      // Return deployments as "fine-tuned models"
      res.json({
        object: 'list',
        data: deployments.map(d => ({
          id: `ft-${d.id}`,
          object: 'fine-tune',
          model: d.model,
          created_at: Math.floor(Date.now() / 1000),
          status: d.status === 'RUNNING' ? 'succeeded' : 'pending',
          fine_tuned_model: d.id,
        })),
      });
    } catch (error: any) {
      res.status(500).json({ error: { message: error.message, type: 'server_error' } });
    }
  });

  app.get('/v1/fine-tunes/:fine_tune_id', authMiddleware, async (req, res) => {
    try {
      const deployments = await getDeployments(config);
      const ftId = req.params.fine_tune_id.replace('ft-', '');
      const deployment = findDeployment(deployments, ftId);
      
      if (!deployment) {
        return res.status(404).json({ 
          error: { message: 'Fine-tune not found', type: 'invalid_request_error' } 
        });
      }

      res.json({
        id: `ft-${deployment.id}`,
        object: 'fine-tune',
        model: deployment.model,
        created_at: Math.floor(Date.now() / 1000),
        status: deployment.status === 'RUNNING' ? 'succeeded' : 'pending',
        fine_tuned_model: deployment.id,
      });
    } catch (error: any) {
      res.status(500).json({ error: { message: error.message, type: 'server_error' } });
    }
  });

  return app;
}

export default createServer;