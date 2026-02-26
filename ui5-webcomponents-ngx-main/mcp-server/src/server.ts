/**
 * UI5 Web Components Angular MCP Server
 * 
 * Model Context Protocol server with Mangle reasoning integration.
 * Provides tools for UI5 Web Components operations.
 */

import express, { Request, Response } from 'express';
import { createServer } from 'http';

// =============================================================================
// Types
// =============================================================================

interface MCPRequest {
  jsonrpc: string;
  id: number | string | null;
  method: string;
  params?: Record<string, unknown>;
}

interface MCPResponse {
  jsonrpc: string;
  id: number | string | null;
  result?: unknown;
  error?: { code: number; message: string };
}

interface Tool {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

// =============================================================================
// MCP Server
// =============================================================================

class MCPServer {
  private tools: Map<string, Tool> = new Map();
  private resources: Map<string, Record<string, string>> = new Map();
  private facts: Record<string, unknown[]> = {};
  private components: Record<string, Record<string, unknown>> = {};

  constructor() {
    this.registerTools();
    this.registerResources();
    this.initializeFacts();
    this.loadComponents();
  }

  private loadComponents(): void {
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

  private registerTools(): void {
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

  private registerResources(): void {
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

  private initializeFacts(): void {
    this.facts = {
      service_registry: [
        { name: "ui5-components", endpoint: "ui5://components", model: "component-registry" },
        { name: "ui5-generator", endpoint: "ui5://generator", model: "template-generator" },
      ],
      tool_invocation: [],
    };
  }

  // Tool Handlers
  private handleListComponents(): Record<string, unknown> {
    return { components: Object.keys(this.components), count: Object.keys(this.components).length };
  }

  private handleGetComponent(args: Record<string, unknown>): Record<string, unknown> {
    const name = args.name as string;
    const component = this.components[name];
    if (component) {
      return { name, ...component };
    }
    return { error: `Component '${name}' not found`, available: Object.keys(this.components) };
  }

  private handleGenerateAngularTemplate(args: Record<string, unknown>): Record<string, unknown> {
    const components = JSON.parse(args.components as string || "[]");
    const layout = args.layout as string || "default";
    
    let template = "";
    if (layout === "form") {
      template = `<div class="ui5-form">\n`;
      components.forEach((c: string) => {
        template += `  <${c}></${c}>\n`;
      });
      template += `</div>`;
    } else if (layout === "card") {
      template = `<ui5-card>\n  <ui5-card-header slot="header" title-text="Card Title"></ui5-card-header>\n`;
      components.forEach((c: string) => {
        template += `  <${c}></${c}>\n`;
      });
      template += `</ui5-card>`;
    } else {
      components.forEach((c: string) => {
        template += `<${c}></${c}>\n`;
      });
    }
    
    return { template, components, layout };
  }

  private handleGenerateModuleImports(args: Record<string, unknown>): Record<string, unknown> {
    const components = JSON.parse(args.components as string || "[]");
    const imports: string[] = [];
    const modules: string[] = [];
    
    components.forEach((c: string) => {
      const comp = this.components[c];
      if (comp) {
        imports.push(`import { ${comp.angular} } from '@ui5/webcomponents-ngx';`);
        modules.push(comp.angular as string);
      }
    });
    
    return {
      imports: imports.join("\n"),
      modules,
      ngModuleImports: `imports: [${modules.join(", ")}]`,
    };
  }

  private handleSearchComponents(args: Record<string, unknown>): Record<string, unknown> {
    const query = (args.query as string || "").toLowerCase();
    const results = Object.entries(this.components)
      .filter(([name]) => name.toLowerCase().includes(query))
      .map(([name, details]) => ({ name, ...details }));
    return { query, results, count: results.length };
  }

  private handleValidateTemplate(args: Record<string, unknown>): Record<string, unknown> {
    const template = args.template as string || "";
    const usedComponents: string[] = [];
    const errors: string[] = [];
    
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

  private handleMangleQuery(args: Record<string, unknown>): Record<string, unknown> {
    const predicate = args.predicate as string;
    const facts = this.facts[predicate];
    if (facts) {
      return { predicate, results: facts };
    }
    return { predicate, results: [], message: "Unknown predicate" };
  }

  handleRequest(request: MCPRequest): MCPResponse {
    const { method, params = {}, id } = request;

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
        const toolName = params.name as string;
        const args = (params.arguments || {}) as Record<string, unknown>;
        const handlers: Record<string, (args: Record<string, unknown>) => Record<string, unknown>> = {
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
        (this.facts.tool_invocation as unknown[]).push({ tool: toolName, timestamp: Date.now() });
        return { jsonrpc: "2.0", id, result: { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] } };
      }

      if (method === "resources/list") {
        return { jsonrpc: "2.0", id, result: { resources: Array.from(this.resources.values()) } };
      }

      if (method === "resources/read") {
        const uri = params.uri as string;
        if (uri === "ui5://components") {
          return { jsonrpc: "2.0", id, result: { contents: [{ uri, mimeType: "application/json", text: JSON.stringify(this.components, null, 2) }] } };
        }
        if (uri === "mangle://facts") {
          return { jsonrpc: "2.0", id, result: { contents: [{ uri, mimeType: "application/json", text: JSON.stringify(this.facts, null, 2) }] } };
        }
        return { jsonrpc: "2.0", id, error: { code: -32602, message: `Unknown resource: ${uri}` } };
      }

      return { jsonrpc: "2.0", id, error: { code: -32601, message: `Method not found: ${method}` } };
    } catch (e) {
      return { jsonrpc: "2.0", id, error: { code: -32603, message: String(e) } };
    }
  }
}

// =============================================================================
// HTTP Server
// =============================================================================

const mcpServer = new MCPServer();
const app = express();
app.use(express.json());

app.use((_req, res, next) => {
  res.header("Access-Control-Allow-Origin", "*");
  res.header("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.header("Access-Control-Allow-Headers", "Content-Type");
  next();
});

app.options("*", (_req, res) => res.sendStatus(204));

app.get("/health", (_req: Request, res: Response) => {
  res.json({ status: "healthy", service: "ui5-webcomponents-ngx-mcp", timestamp: new Date().toISOString() });
});

app.post("/mcp", (req: Request, res: Response) => {
  const response = mcpServer.handleRequest(req.body);
  res.json(response);
});

const port = parseInt(process.argv.find(a => a.startsWith("--port="))?.split("=")[1] || "9160");
createServer(app).listen(port, () => {
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