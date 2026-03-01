"use strict";
/**
 * UI5 Web Components Angular MCP Server
 *
 * Model Context Protocol server with Mangle reasoning integration.
 * Provides tools for UI5 Web Components operations.
 */
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const express_1 = __importDefault(require("express"));
const http_1 = require("http");
const MAX_JSON_BODY_BYTES = 1024 * 1024;
const MAX_COMPONENTS_PER_REQUEST = 64;
const MAX_SEARCH_QUERY_LENGTH = 200;
function parseJsonArrayArg(value) {
    const normalize = (items) => items.filter((v) => typeof v === "string").slice(0, MAX_COMPONENTS_PER_REQUEST);
    if (Array.isArray(value)) {
        return normalize(value);
    }
    if (typeof value !== "string")
        return [];
    try {
        const parsed = JSON.parse(value);
        if (!Array.isArray(parsed))
            return [];
        return normalize(parsed);
    }
    catch {
        return [];
    }
}
function isValidJsonRpcRequest(value) {
    if (!value || typeof value !== "object")
        return false;
    const req = value;
    return req.jsonrpc === "2.0" && typeof req.method === "string";
}
// =============================================================================
// MCP Server
// =============================================================================
class MCPServer {
    constructor() {
        this.tools = new Map();
        this.resources = new Map();
        this.facts = {};
        this.components = {};
        this.registerTools();
        this.registerResources();
        this.initializeFacts();
        this.loadComponents();
    }
    loadComponents() {
        this.components = {
            "ui5-button": { tag: "ui5-button", module: "@ui5/webcomponents/dist/Button", angular: "Ui5ButtonModule" },
            "ui5-input": { tag: "ui5-input", module: "@ui5/webcomponents/dist/Input", angular: "Ui5InputModule" },
            "ui5-table": { tag: "ui5-table", module: "@ui5/webcomponents/dist/Table", angular: "Ui5TableModule" },
            "ui5-dialog": { tag: "ui5-dialog", module: "@ui5/webcomponents/dist/Dialog", angular: "Ui5DialogModule" },
            "ui5-card": { tag: "ui5-card", module: "@ui5/webcomponents/dist/Card", angular: "Ui5CardModule" },
            "ui5-list": { tag: "ui5-list", module: "@ui5/webcomponents/dist/List", angular: "Ui5ListModule" },
            "ui5-panel": { tag: "ui5-panel", module: "@ui5/webcomponents/dist/Panel", angular: "Ui5PanelModule" },
            "ui5-tabcontainer": { tag: "ui5-tabcontainer", module: "@ui5/webcomponents/dist/TabContainer", angular: "Ui5TabContainerModule" },
        };
    }
    registerTools() {
        this.tools.set("list_components", {
            name: "list_components",
            description: "List all available UI5 Web Components",
            inputSchema: { type: "object", properties: {} },
        });
        this.tools.set("get_component", {
            name: "get_component",
            description: "Get details of a specific UI5 Web Component",
            inputSchema: {
                type: "object",
                properties: { name: { type: "string", description: "Component name (e.g., ui5-button)" } },
                required: ["name"],
            },
        });
        this.tools.set("generate_angular_template", {
            name: "generate_angular_template",
            description: "Generate Angular template using UI5 Web Components",
            inputSchema: {
                type: "object",
                properties: {
                    components: { type: "string", description: "JSON array of component names" },
                    layout: { type: "string", description: "Layout type (form, list, card)" },
                },
                required: ["components"],
            },
        });
        this.tools.set("generate_module_imports", {
            name: "generate_module_imports",
            description: "Generate Angular module imports for UI5 components",
            inputSchema: {
                type: "object",
                properties: { components: { type: "string", description: "JSON array of component names" } },
                required: ["components"],
            },
        });
        this.tools.set("search_components", {
            name: "search_components",
            description: "Search UI5 components by keyword",
            inputSchema: {
                type: "object",
                properties: { query: { type: "string", description: "Search query" } },
                required: ["query"],
            },
        });
        this.tools.set("validate_template", {
            name: "validate_template",
            description: "Validate an Angular template using UI5 components",
            inputSchema: {
                type: "object",
                properties: { template: { type: "string", description: "Angular template HTML" } },
                required: ["template"],
            },
        });
        this.tools.set("mangle_query", {
            name: "mangle_query",
            description: "Query the Mangle reasoning engine",
            inputSchema: {
                type: "object",
                properties: {
                    predicate: { type: "string", description: "Predicate to query" },
                    args: { type: "string", description: "Arguments as JSON array" },
                },
                required: ["predicate"],
            },
        });
    }
    registerResources() {
        this.resources.set("ui5://components", {
            uri: "ui5://components",
            name: "UI5 Components",
            description: "All UI5 Web Components",
            mimeType: "application/json",
        });
        this.resources.set("ui5://modules", {
            uri: "ui5://modules",
            name: "Angular Modules",
            description: "UI5 Angular modules",
            mimeType: "application/json",
        });
        this.resources.set("mangle://facts", {
            uri: "mangle://facts",
            name: "Mangle Facts",
            description: "Mangle fact store",
            mimeType: "application/json",
        });
    }
    initializeFacts() {
        this.facts = {
            service_registry: [
                { name: "ui5-components", endpoint: "ui5://components", model: "component-registry" },
                { name: "ui5-generator", endpoint: "ui5://generator", model: "template-generator" },
            ],
            tool_invocation: [],
        };
    }
    // Tool Handlers
    handleListComponents() {
        return { components: Object.keys(this.components), count: Object.keys(this.components).length };
    }
    handleGetComponent(args) {
        const name = args.name;
        const component = this.components[name];
        if (component) {
            return { name, ...component };
        }
        return { error: `Component '${name}' not found`, available: Object.keys(this.components) };
    }
    handleGenerateAngularTemplate(args) {
        const components = parseJsonArrayArg(args.components).filter(c => !!this.components[c]);
        const layout = args.layout || "default";
        let template = "";
        if (layout === "form") {
            template = `<div class="ui5-form">\n`;
            components.forEach((c) => {
                template += `  <${c}></${c}>\n`;
            });
            template += `</div>`;
        }
        else if (layout === "card") {
            template = `<ui5-card>\n  <ui5-card-header slot="header" title-text="Card Title"></ui5-card-header>\n`;
            components.forEach((c) => {
                template += `  <${c}></${c}>\n`;
            });
            template += `</ui5-card>`;
        }
        else {
            components.forEach((c) => {
                template += `<${c}></${c}>\n`;
            });
        }
        return { template, components, layout };
    }
    handleGenerateModuleImports(args) {
        const components = parseJsonArrayArg(args.components).filter(c => !!this.components[c]);
        const imports = [];
        const modules = [];
        components.forEach((c) => {
            const comp = this.components[c];
            if (comp) {
                imports.push(`import { ${comp.angular} } from '@ui5/webcomponents-ngx';`);
                modules.push(comp.angular);
            }
        });
        return {
            imports: imports.join("\n"),
            modules,
            ngModuleImports: `imports: [${modules.join(", ")}]`,
        };
    }
    handleSearchComponents(args) {
        const query = String(args.query || "").slice(0, MAX_SEARCH_QUERY_LENGTH).toLowerCase();
        const results = Object.entries(this.components)
            .filter(([name]) => name.toLowerCase().includes(query))
            .map(([name, details]) => ({ name, ...details }));
        return { query, results, count: results.length };
    }
    handleValidateTemplate(args) {
        const template = args.template || "";
        const usedComponents = [];
        const errors = [];
        Object.keys(this.components).forEach(comp => {
            if (template.includes(`<${comp}`)) {
                usedComponents.push(comp);
            }
        });
        // Check for unknown components
        const tagMatch = template.match(/<ui5-[a-z-]+/g);
        if (tagMatch) {
            tagMatch.forEach(tag => {
                const tagName = tag.slice(1);
                if (!this.components[tagName]) {
                    errors.push(`Unknown component: ${tagName}`);
                }
            });
        }
        return { valid: errors.length === 0, usedComponents, errors };
    }
    handleMangleQuery(args) {
        const predicate = args.predicate;
        const facts = this.facts[predicate];
        if (facts) {
            return { predicate, results: facts };
        }
        return { predicate, results: [], message: "Unknown predicate" };
    }
    handleRequest(request) {
        if (!isValidJsonRpcRequest(request)) {
            return { jsonrpc: "2.0", id: null, error: { code: -32600, message: "Invalid Request" } };
        }
        const { method, params = {}, id } = request;
        if (params !== null && typeof params !== "object") {
            return { jsonrpc: "2.0", id, error: { code: -32600, message: "Invalid Request: params must be an object" } };
        }
        try {
            if (method === "initialize") {
                return {
                    jsonrpc: "2.0",
                    id,
                    result: {
                        protocolVersion: "2024-11-05",
                        capabilities: { tools: { listChanged: true }, resources: { listChanged: true }, prompts: { listChanged: true } },
                        serverInfo: { name: "ui5-webcomponents-ngx-mcp", version: "1.0.0" },
                    },
                };
            }
            if (method === "tools/list") {
                return { jsonrpc: "2.0", id, result: { tools: Array.from(this.tools.values()) } };
            }
            if (method === "tools/call") {
                const toolName = params.name;
                if (typeof toolName !== "string") {
                    return { jsonrpc: "2.0", id, error: { code: -32602, message: 'tools/call requires string param "name"' } };
                }
                if (params.arguments !== undefined && (params.arguments === null || typeof params.arguments !== "object" || Array.isArray(params.arguments))) {
                    return { jsonrpc: "2.0", id, error: { code: -32602, message: 'tools/call param "arguments" must be an object' } };
                }
                const args = (params.arguments || {});
                const handlers = {
                    list_components: () => this.handleListComponents(),
                    get_component: (a) => this.handleGetComponent(a),
                    generate_angular_template: (a) => this.handleGenerateAngularTemplate(a),
                    generate_module_imports: (a) => this.handleGenerateModuleImports(a),
                    search_components: (a) => this.handleSearchComponents(a),
                    validate_template: (a) => this.handleValidateTemplate(a),
                    mangle_query: (a) => this.handleMangleQuery(a),
                };
                const handler = handlers[toolName];
                if (!handler) {
                    return { jsonrpc: "2.0", id, error: { code: -32602, message: `Unknown tool: ${toolName}` } };
                }
                const result = handler(args);
                this.facts.tool_invocation.push({ tool: toolName, timestamp: Date.now() });
                return { jsonrpc: "2.0", id, result: { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] } };
            }
            if (method === "resources/list") {
                return { jsonrpc: "2.0", id, result: { resources: Array.from(this.resources.values()) } };
            }
            if (method === "resources/read") {
                const uri = params.uri;
                if (uri === "ui5://components") {
                    return { jsonrpc: "2.0", id, result: { contents: [{ uri, mimeType: "application/json", text: JSON.stringify(this.components, null, 2) }] } };
                }
                if (uri === "mangle://facts") {
                    return { jsonrpc: "2.0", id, result: { contents: [{ uri, mimeType: "application/json", text: JSON.stringify(this.facts, null, 2) }] } };
                }
                return { jsonrpc: "2.0", id, error: { code: -32602, message: `Unknown resource: ${uri}` } };
            }
            return { jsonrpc: "2.0", id, error: { code: -32601, message: `Method not found: ${method}` } };
        }
        catch (e) {
            return { jsonrpc: "2.0", id, error: { code: -32603, message: String(e) } };
        }
    }
}
// =============================================================================
// HTTP Server
// =============================================================================
const mcpServer = new MCPServer();
const app = (0, express_1.default)();
app.use(express_1.default.json({ limit: `${MAX_JSON_BODY_BYTES}b` }));
app.use((_req, res, next) => {
    res.header("Access-Control-Allow-Origin", "*");
    res.header("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    res.header("Access-Control-Allow-Headers", "Content-Type");
    next();
});
app.options("*", (_req, res) => res.sendStatus(204));
app.use((err, _req, res, next) => {
    if (err && typeof err === "object" && "type" in err && err.type === "entity.parse.failed") {
        return res.status(400).json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
    }
    if (err && typeof err === "object" && "type" in err && err.type === "entity.too.large") {
        return res.status(413).json({ jsonrpc: "2.0", id: null, error: { code: -32600, message: "Request too large" } });
    }
    return next(err);
});
app.get("/health", (_req, res) => {
    res.json({
        status: "healthy",
        service: "ui5-webcomponents-ngx-mcp",
        timestamp: new Date().toISOString(),
        uptimeSeconds: Math.round(process.uptime()),
    });
});
app.post("/mcp", (req, res) => {
    if (!isValidJsonRpcRequest(req.body)) {
        return res.status(400).json({ jsonrpc: "2.0", id: null, error: { code: -32600, message: "Invalid Request" } });
    }
    const response = mcpServer.handleRequest(req.body);
    return res.json(response);
});
const requestedPort = parseInt(process.argv.find(a => a.startsWith("--port="))?.split("=")[1] || "9160", 10);
const port = Number.isInteger(requestedPort) && requestedPort > 0 && requestedPort <= 65535 ? requestedPort : 9160;
(0, http_1.createServer)(app).listen(port, () => {
    console.log(`
╔══════════════════════════════════════════════════════════╗
║   UI5 Web Components Angular MCP Server                  ║
║   Model Context Protocol v2024-11-05                     ║
╚══════════════════════════════════════════════════════════╝

Server: http://localhost:${port}

Tools: list_components, get_component, generate_angular_template,
       generate_module_imports, search_components, validate_template,
       mangle_query

Resources: ui5://components, ui5://modules, mangle://facts
`);
});
//# sourceMappingURL=server.js.map