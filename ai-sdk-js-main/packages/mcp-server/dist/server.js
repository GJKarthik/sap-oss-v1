"use strict";
/**
 * SAP AI SDK MCP Server
 *
 * Model Context Protocol server with Mangle reasoning integration.
 * Provides tools, resources, and prompts for SAP AI Core operations.
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
exports.httpServer = exports.MCPServer = void 0;
const http = __importStar(require("http"));
const https = __importStar(require("https"));
const url_1 = require("url");
const ws_1 = require("ws");
const REMOTE_MCP_TIMEOUT_MS = 2500;
function safeJsonParse(value, fallback) {
    if (typeof value !== 'string')
        return fallback;
    try {
        return JSON.parse(value);
    }
    catch {
        return fallback;
    }
}
function normalizeMcpEndpoint(endpoint) {
    const trimmed = endpoint.trim().replace(/\/+$/, '');
    return trimmed.endsWith('/mcp') ? trimmed : `${trimmed}/mcp`;
}
function getRemoteMcpEndpoints(envKey) {
    const raw = process.env[envKey] || '';
    return raw
        .split(',')
        .map(v => v.trim())
        .filter(Boolean)
        .map(normalizeMcpEndpoint);
}
function unwrapMcpToolResult(result) {
    if (!result || typeof result !== 'object')
        return result;
    const content = result.content;
    if (!Array.isArray(content) || content.length === 0)
        return result;
    const first = content[0];
    if (!first || typeof first !== 'object')
        return result;
    const text = first.text;
    if (typeof text !== 'string')
        return result;
    return safeJsonParse(text, text);
}
async function callMcpTool(endpoint, toolName, toolArgs, timeoutMs = REMOTE_MCP_TIMEOUT_MS) {
    const target = new url_1.URL(endpoint);
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
            res.on('data', (chunk) => data += chunk);
            res.on('end', () => {
                try {
                    const rpc = JSON.parse(data);
                    if (rpc.error) {
                        return reject(new Error(rpc.error.message || 'remote MCP error'));
                    }
                    resolve(unwrapMcpToolResult(rpc.result));
                }
                catch (err) {
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
        const url = new url_1.URL(config.authUrl);
        const req = https.request({
            hostname: url.hostname,
            port: 443,
            path: url.pathname,
            method: 'POST',
            headers: { 'Authorization': `Basic ${auth}`, 'Content-Type': 'application/x-www-form-urlencoded' },
        }, (res) => {
            let data = '';
            res.on('data', (chunk) => data += chunk);
            res.on('end', () => {
                try {
                    const result = JSON.parse(data);
                    cachedToken = { token: result.access_token, expiresAt: Date.now() + (result.expires_in - 60) * 1000 };
                    resolve(result.access_token);
                }
                catch (e) {
                    reject(e);
                }
            });
        });
        req.on('error', reject);
        req.write('grant_type=client_credentials');
        req.end();
    });
}
async function aicoreRequest(config, method, path, body) {
    const token = await getAccessToken(config);
    const url = new url_1.URL(path, config.baseUrl);
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
            res.on('data', (chunk) => data += chunk);
            res.on('end', () => {
                try {
                    resolve(JSON.parse(data));
                }
                catch {
                    resolve(data);
                }
            });
        });
        req.on('error', reject);
        if (body)
            req.write(JSON.stringify(body));
        req.end();
    });
}
// =============================================================================
// MCP Server Implementation
// =============================================================================
class MCPServer {
    constructor() {
        this.tools = new Map();
        this.resources = new Map();
        this.prompts = new Map();
        this.toolHandlers = new Map();
        this.facts = new Map(); // Mangle fact store
        this.registerTools();
        this.registerResources();
        this.registerPrompts();
        this.initializeFacts();
    }
    // ===========================================================================
    // Tool Registration
    // ===========================================================================
    registerTools() {
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
    }
    // ===========================================================================
    // Resource Registration
    // ===========================================================================
    registerResources() {
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
    registerPrompts() {
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
    initializeFacts() {
        const localPort = Number.parseInt(process.env.MCP_PORT || '9090', 10) || 9090;
        const serviceRegistry = [
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
    getFederatedMcpEndpoints() {
        const endpoints = new Set();
        getRemoteMcpEndpoints('AI_SDK_REMOTE_MCP_ENDPOINTS').forEach(endpoint => endpoints.add(endpoint));
        const orchestrationEndpoint = process.env.AI_SDK_ORCHESTRATION_MCP_ENDPOINT;
        if (orchestrationEndpoint && orchestrationEndpoint.trim() !== '') {
            endpoints.add(normalizeMcpEndpoint(orchestrationEndpoint));
        }
        const services = this.facts.get('service_registry');
        if (Array.isArray(services)) {
            services.forEach((service) => {
                if (!service || typeof service !== 'object')
                    return;
                const endpoint = service.endpoint;
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
    async handleChatTool(args) {
        const config = getConfig();
        const messages = typeof args.messages === 'string' ? JSON.parse(args.messages) : args.messages;
        // Get deployments
        const deploymentsResult = await aicoreRequest(config, 'GET', '/v2/lm/deployments');
        const deployments = deploymentsResult.resources || [];
        // Find deployment
        const modelId = args.model || 'claude';
        const deployment = deployments.find(d => d.id === modelId ||
            d.details?.resources?.backend_details?.model?.name?.toLowerCase().includes(modelId.toLowerCase())) || deployments[0];
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
            });
            return { content: result.content?.[0]?.text || '', model: deployment.id };
        }
        else {
            const result = await aicoreRequest(config, 'POST', `/v2/inference/deployments/${deployment.id}/chat/completions`, {
                messages,
                max_tokens: args.max_tokens,
                temperature: args.temperature,
            });
            return result;
        }
    }
    async handleEmbedTool(args) {
        const config = getConfig();
        const input = typeof args.input === 'string' ?
            (args.input.startsWith('[') ? JSON.parse(args.input) : [args.input]) :
            [args.input];
        const deploymentsResult = await aicoreRequest(config, 'GET', '/v2/lm/deployments');
        const deployments = deploymentsResult.resources || [];
        const deployment = deployments.find(d => d.details?.resources?.backend_details?.model?.name?.toLowerCase().includes('embed')) || deployments[0];
        if (!deployment) {
            return { error: 'No embedding deployment available' };
        }
        const result = await aicoreRequest(config, 'POST', `/v2/inference/deployments/${deployment.id}/embeddings`, {
            input,
            model: args.model,
        });
        return result;
    }
    async handleVectorSearchTool(args) {
        // This would integrate with HANA Cloud vector store
        // For now, return a placeholder
        return {
            results: [],
            query: args.query,
            table_name: args.table_name,
            message: 'Connect to HANA Cloud for actual vector search',
        };
    }
    async handleListDeploymentsTool(_args) {
        const config = getConfig();
        const result = await aicoreRequest(config, 'GET', '/v2/lm/deployments');
        // Update Mangle facts
        this.facts.set('deployment', result.resources || []);
        return result;
    }
    async handleOrchestrationTool(args) {
        // Orchestration scenarios
        const scenario = args.scenario;
        const input = typeof args.input === 'string' ? safeJsonParse(args.input, args.input) : args.input;
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
            }
            catch {
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
    async handleMangleQueryTool(args) {
        const predicate = args.predicate;
        const queryArgs = Array.isArray(args.args) ? args.args : safeJsonParse(args.args, []);
        // Simple fact lookup
        const facts = this.facts.get(predicate);
        if (facts) {
            return { predicate, results: facts };
        }
        // Derived predicates
        if (predicate === 'deployment_ready') {
            const deployments = this.facts.get('deployment') || [];
            const ready = deployments.filter(d => d.status === 'RUNNING');
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
                    const results = remoteResult.results;
                    if (Array.isArray(results) && results.length > 0) {
                        return { predicate, results, source: endpoint };
                    }
                }
            }
            catch {
                // Try next endpoint.
            }
        }
        return { predicate, args: queryArgs, results: [], message: 'Unknown predicate' };
    }
    // ===========================================================================
    // MCP Protocol Handlers
    // ===========================================================================
    async handleRequest(request) {
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
        }
        catch (error) {
            return {
                jsonrpc: '2.0',
                id,
                error: { code: -32603, message: String(error) },
            };
        }
    }
    handleInitialize(id, _params) {
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
    handleToolsList(id) {
        return {
            jsonrpc: '2.0',
            id,
            result: {
                tools: Array.from(this.tools.values()),
            },
        };
    }
    async handleToolsCall(id, params) {
        const toolName = params?.name;
        const args = (params?.arguments || {});
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
    handleResourcesList(id) {
        return {
            jsonrpc: '2.0',
            id,
            result: {
                resources: Array.from(this.resources.values()),
            },
        };
    }
    async handleResourcesRead(id, params) {
        const uri = params?.uri;
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
            const allFacts = {};
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
    handlePromptsList(id) {
        return {
            jsonrpc: '2.0',
            id,
            result: {
                prompts: Array.from(this.prompts.values()),
            },
        };
    }
    handlePromptsGet(id, params) {
        const promptName = params?.name;
        const prompt = this.prompts.get(promptName);
        if (!prompt) {
            return {
                jsonrpc: '2.0',
                id,
                error: { code: -32602, message: `Unknown prompt: ${promptName}` },
            };
        }
        // Generate prompt messages based on arguments
        const args = (params?.arguments || {});
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
    getMangleRules() {
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
exports.MCPServer = MCPServer;
// =============================================================================
// HTTP + WebSocket Server
// =============================================================================
const PORT = parseInt(process.env.MCP_PORT || process.argv.find(a => a.startsWith('--port='))?.split('=')[1] || '9090');
const mcpServer = new MCPServer();
// HTTP Server for SSE transport
const httpServer = http.createServer(async (req, res) => {
    // CORS
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
    if (req.method === 'OPTIONS') {
        res.writeHead(204);
        res.end();
        return;
    }
    const url = new url_1.URL(req.url || '/', `http://${req.headers.host}`);
    // Health check
    if (url.pathname === '/health') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'healthy', service: 'sap-ai-sdk-mcp-server', timestamp: new Date().toISOString() }));
        return;
    }
    // MCP JSON-RPC endpoint
    if (url.pathname === '/mcp' && req.method === 'POST') {
        let body = '';
        req.on('data', (chunk) => body += chunk);
        req.on('end', async () => {
            try {
                const request = JSON.parse(body);
                const response = await mcpServer.handleRequest(request);
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify(response));
            }
            catch (error) {
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
exports.httpServer = httpServer;
// WebSocket Server for stdio-over-websocket
const wss = new ws_1.WebSocketServer({ server: httpServer, path: '/mcp/ws' });
wss.on('connection', (ws) => {
    console.log('MCP WebSocket client connected');
    ws.on('message', async (data) => {
        try {
            const request = JSON.parse(data.toString());
            const response = await mcpServer.handleRequest(request);
            ws.send(JSON.stringify(response));
        }
        catch (error) {
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

Resources:
  - deployment://list   - AI Core deployments
  - mangle://facts      - Mangle fact store
  - mangle://rules      - Mangle reasoning rules

Prompts:
  - rag_query           - RAG query template
  - data_analysis       - Data analysis template
`);
});
