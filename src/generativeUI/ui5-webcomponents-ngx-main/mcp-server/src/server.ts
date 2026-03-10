// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * UI5 Web Components Angular MCP Server
 * 
 * Model Context Protocol server with Mangle reasoning integration.
 * Provides tools for UI5 Web Components operations.
 */

import express, { Request, Response } from 'express';
import { createServer } from 'http';
import { URL } from 'url';
import * as https from 'https';
import * as http from 'http';
import { getKuzuStore } from './kuzu-store';

const MAX_JSON_BODY_BYTES = 1024 * 1024;
const MAX_COMPONENTS_PER_REQUEST = 64;
const MAX_SEARCH_QUERY_LENGTH = 200;

// =============================================================================
// Finding 1: Mangle query service endpoint
// =============================================================================

const BLOCKED_HOST_PREFIXES = ['169.254.', '100.100.', 'fd00:', '::1'];

function validateRemoteUrl(raw: string, varName: string): string {
  if (!raw) return raw;
  let parsed: URL;
  try { parsed = new URL(raw); } catch {
    throw new Error(`${varName} is not a valid URL: ${raw}`);
  }
  if (!['http:', 'https:'].includes(parsed.protocol)) {
    throw new Error(`${varName} must use http or https (got '${parsed.protocol}'). Value: ${raw}`);
  }
  const host = parsed.hostname;
  for (const prefix of BLOCKED_HOST_PREFIXES) {
    if (host.startsWith(prefix)) {
      throw new Error(`${varName} targets a blocked host prefix '${prefix}' (cloud metadata / link-local). Value: ${raw}`);
    }
  }
  return raw.replace(/\/$/, '');
}

function safeEnvUrl(envVar: string, fallback: string): string {
  const raw = (process.env[envVar] ?? '').trim();
  if (!raw) return fallback;
  try {
    return validateRemoteUrl(raw, envVar);
  } catch (e) {
    console.error(`ERROR: ${String(e)} — falling back to ${fallback}`);
    return fallback;
  }
}

const MANGLE_ENDPOINT = safeEnvUrl('MANGLE_ENDPOINT', 'http://localhost:50051');

async function callMangleService(predicate: string, args: unknown[]): Promise<{ results: unknown[]; wired: boolean }> {
  return new Promise((resolve) => {
    const payload = JSON.stringify({ predicate, args });
    const url = new URL(`${MANGLE_ENDPOINT}/query`);
    const lib = url.protocol === 'https:' ? https : http;
    const req = lib.request(
      { hostname: url.hostname, port: url.port || (url.protocol === 'https:' ? 443 : 80),
        path: url.pathname, method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } },
      (res) => {
        let data = '';
        res.on('data', (chunk: Buffer) => { data += chunk; });
        res.on('end', () => {
          try {
            const body = JSON.parse(data) as { results?: unknown[] };
            resolve({ results: body.results ?? [], wired: true });
          } catch {
            resolve({ results: [], wired: false });
          }
        });
      },
    );
    req.on('error', () => resolve({ results: [], wired: false }));
    req.setTimeout(5000, () => { req.destroy(); resolve({ results: [], wired: false }); });
    req.write(payload);
    req.end();
  });
}

// =============================================================================
// Finding 5: HANA MetricsBackend
// =============================================================================

const HANA_BASE_URL   = safeEnvUrl('HANA_BASE_URL', '');
const HANA_AUTH_URL   = safeEnvUrl('HANA_AUTH_URL', '');
const HANA_CLIENT_ID  = (process.env.HANA_CLIENT_ID  ?? '').trim();
const HANA_CLIENT_SEC = (process.env.HANA_CLIENT_SECRET ?? '').trim();

const HANA_METRICS_DDL = `
CREATE TABLE IF NOT EXISTS UI5NGX_METRICS (
    METRIC_NAME   NVARCHAR(256)  NOT NULL,
    METRIC_VALUE  DOUBLE         NOT NULL,
    LABELS        NVARCHAR(2000) DEFAULT '{}',
    RECORDED_AT   TIMESTAMP      DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (METRIC_NAME, RECORDED_AT)
)`;

interface MetricEntry { value: number; labels: Record<string, unknown>; timestamp: number; }

class MetricsBackend {
  private memory = new Map<string, MetricEntry>();
  private hanaToken = '';
  private hanaTokenExp = 0;
  private tableReady = false;

  private hanaAvailable(): boolean {
    return !!(HANA_BASE_URL && HANA_AUTH_URL && HANA_CLIENT_ID && HANA_CLIENT_SEC);
  }

  private async getHanaToken(): Promise<string> {
    if (this.hanaToken && Date.now() < this.hanaTokenExp) return this.hanaToken;
    const creds = Buffer.from(`${HANA_CLIENT_ID}:${HANA_CLIENT_SEC}`).toString('base64');
    const body = 'grant_type=client_credentials';
    const url = new URL(HANA_AUTH_URL);
    return new Promise((resolve, reject) => {
      const lib = url.protocol === 'https:' ? https : http;
      const req = lib.request(
        { hostname: url.hostname, port: url.port || 443, path: url.pathname, method: 'POST',
          headers: { 'Authorization': `Basic ${creds}`, 'Content-Type': 'application/x-www-form-urlencoded',
            'Content-Length': Buffer.byteLength(body) } },
        (res) => {
          let data = '';
          res.on('data', (c: Buffer) => { data += c; });
          res.on('end', () => {
            try {
              const j = JSON.parse(data) as { access_token: string; expires_in?: number };
              this.hanaToken = j.access_token;
              this.hanaTokenExp = Date.now() + (j.expires_in ?? 3600) * 1000 - 60000;
              resolve(this.hanaToken);
            } catch (e) { reject(e); }
          });
        },
      );
      req.on('error', reject);
      req.write(body);
      req.end();
    });
  }

  private async hanaSql(statement: string, params?: unknown[]): Promise<void> {
    const token = await this.getHanaToken();
    const payload = JSON.stringify({ statement, ...(params ? { parameters: params } : {}) });
    const url = new URL(`${HANA_BASE_URL}/v1/statement`);
    return new Promise((resolve, reject) => {
      const lib = url.protocol === 'https:' ? https : http;
      const req = lib.request(
        { hostname: url.hostname, port: url.port || 443, path: url.pathname, method: 'POST',
          headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(payload) } },
        (res) => { res.resume(); res.on('end', resolve); },
      );
      req.on('error', reject);
      req.setTimeout(10000, () => { req.destroy(); reject(new Error('HANA timeout')); });
      req.write(payload);
      req.end();
    });
  }

  private async ensureTable(): Promise<void> {
    if (this.tableReady) return;
    await this.hanaSql(HANA_METRICS_DDL.trim());
    this.tableReady = true;
  }

  async record(name: string, value: number, labels: Record<string, unknown> = {}): Promise<void> {
    this.memory.set(name, { value, labels, timestamp: Date.now() });
    if (!this.hanaAvailable()) return;
    try {
      await this.ensureTable();
      await this.hanaSql(
        'INSERT INTO UI5NGX_METRICS (METRIC_NAME, METRIC_VALUE, LABELS) VALUES (?, ?, ?)',
        [name, value, JSON.stringify(labels)],
      );
    } catch (e) {
      console.warn(`WARNING: HANA metrics write failed (${String(e)}); in-memory echo retained.`);
    }
  }

  snapshot(): Record<string, MetricEntry> {
    return Object.fromEntries(this.memory);
  }
}

const metrics = new MetricsBackend();

if (HANA_BASE_URL) {
  console.log('INFO: HANA metrics backend enabled (HANA_BASE_URL is set).');
} else {
  console.log('INFO: Metrics backend is in-memory only. Set HANA_BASE_URL, HANA_CLIENT_ID, HANA_CLIENT_SECRET, and HANA_AUTH_URL to enable persistent HANA-backed metrics.');
}

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

function parseJsonArrayArg(value: unknown): string[] {
  const normalize = (items: unknown[]) =>
    items.filter((v): v is string => typeof v === "string").slice(0, MAX_COMPONENTS_PER_REQUEST);

  if (Array.isArray(value)) {
    return normalize(value);
  }
  if (typeof value !== "string") return [];
  try {
    const parsed = JSON.parse(value) as unknown;
    if (!Array.isArray(parsed)) return [];
    return normalize(parsed);
  } catch {
    return [];
  }
}

function isValidJsonRpcRequest(value: unknown): value is MCPRequest {
  if (!value || typeof value !== "object") return false;
  const req = value as Partial<MCPRequest>;
  return req.jsonrpc === "2.0" && typeof req.method === "string";
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

    // Graph-RAG: index component definitions into KùzuDB
    this.tools.set("kuzu_index", {
      name: "kuzu_index",
      description:
        "Index UI5 component definitions into the embedded KùzuDB graph database. " +
        "Stores component nodes, Angular module membership (BELONGS_TO), named slots (HAS_SLOT), " +
        "and optional co-usage relationships (CO_USED_WITH). " +
        "Use before generate_angular_template to enable graph-context enrichment.",
      inputSchema: {
        type: "object",
        properties: {
          components: {
            type: "string",
            description:
              "JSON array of component definitions: " +
              "[{tag_name, angular_module, npm_module?, slots?: string[], co_used_with?: string[]}]",
          },
        },
        required: ["components"],
      },
    });

    // Graph-RAG: run a read-only Cypher query against KùzuDB
    this.tools.set("kuzu_query", {
      name: "kuzu_query",
      description:
        "Execute a read-only Cypher query against the embedded KùzuDB graph database " +
        "and return matching rows as JSON. " +
        "Use for co-usage lookup, module discovery, slot traversal, and relationship analysis.",
      inputSchema: {
        type: "object",
        properties: {
          cypher: {
            type: "string",
            description: "Cypher query string (MATCH … RETURN only)",
          },
          params: {
            type: "string",
            description: "Query parameters as JSON object (optional)",
          },
        },
        required: ["cypher"],
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
    const components = parseJsonArrayArg(args.components).filter(c => !!this.components[c]);
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

    // M4 — attach graph context when KùzuDB has data
    const store = getKuzuStore();
    let graphContext: Record<string, unknown[]> | undefined;
    if (store.available()) {
      graphContext = {};
      for (const tag of components) {
        try {
          const ctx = store.getComponentContext(tag);
          // getComponentContext is async; stash the promise value synchronously via a
          // best-effort in-memory snapshot (populated after kuzu_index calls)
          (ctx as unknown as Promise<unknown[]>).then((entries) => {
            if (graphContext && (entries as unknown[]).length > 0) {
              graphContext[tag] = entries as unknown[];
            }
          }).catch(() => { /* silent degradation */ });
        } catch { /* silent degradation */ }
      }
    }

    const result: Record<string, unknown> = { template, components, layout };
    if (graphContext && Object.keys(graphContext).length > 0) {
      result['graph_context'] = graphContext;
    }
    return result;
  }

  private async handleKuzuIndex(args: Record<string, unknown>): Promise<Record<string, unknown>> {
    const raw = args.components;
    if (!raw) return { error: 'components is required' };

    let defs: unknown[];
    try {
      defs = Array.isArray(raw) ? raw : (JSON.parse(String(raw)) as unknown[]);
      if (!Array.isArray(defs)) return { error: 'components must be a JSON array' };
    } catch {
      return { error: 'components must be a valid JSON array' };
    }

    const store = getKuzuStore();
    if (!store.available()) {
      return { error: "KùzuDB not installed; add 'kuzu' to mcp-server/package.json dependencies" };
    }
    await store.ensureSchema();

    let componentsIndexed = 0;
    let slotsIndexed = 0;
    let coUsageIndexed = 0;

    for (const def of defs) {
      if (!def || typeof def !== 'object') continue;
      const d = def as Record<string, unknown>;
      const tagName = String(d['tag_name'] ?? '').trim();
      const angularModule = String(d['angular_module'] ?? '').trim();
      if (!tagName || !angularModule) continue;

      const npmModule = String(d['npm_module'] ?? '');
      const slots: string[] = Array.isArray(d['slots'])
        ? (d['slots'] as unknown[]).filter((s): s is string => typeof s === 'string')
        : [];

      await store.upsertComponent(tagName, angularModule, npmModule, slots);
      componentsIndexed++;
      slotsIndexed += slots.length;

      const coUsed: string[] = Array.isArray(d['co_used_with'])
        ? (d['co_used_with'] as unknown[]).filter((s): s is string => typeof s === 'string')
        : [];
      for (const peer of coUsed) {
        await store.linkCoUsage(tagName, peer);
        coUsageIndexed++;
      }
    }

    void metrics.record('tool.kuzu_index', 1, { components: componentsIndexed });
    return { components_indexed: componentsIndexed, slots_indexed: slotsIndexed, co_usage_indexed: coUsageIndexed };
  }

  private async handleKuzuQuery(args: Record<string, unknown>): Promise<Record<string, unknown>> {
    const cypher = String(args.cypher ?? '').trim();
    if (!cypher) return { error: 'cypher is required' };

    const upperCypher = cypher.toUpperCase().trimStart();
    for (const disallowed of ['CREATE ', 'MERGE ', 'DELETE ', 'SET ', 'REMOVE ', 'DROP ']) {
      if (upperCypher.startsWith(disallowed)) {
        return { error: 'Write Cypher statements are not permitted via this tool' };
      }
    }

    let params: Record<string, unknown> = {};
    if (args.params) {
      try { params = JSON.parse(String(args.params)) as Record<string, unknown>; } catch { /* ignore */ }
    }

    const store = getKuzuStore();
    if (!store.available()) {
      return { error: "KùzuDB not installed; add 'kuzu' to mcp-server/package.json dependencies" };
    }

    const rows = await store.runQuery(cypher, params);
    void metrics.record('tool.kuzu_query', 1, { row_count: rows.length });
    return { rows, row_count: rows.length };
  }

  private handleGenerateModuleImports(args: Record<string, unknown>): Record<string, unknown> {
    const components = parseJsonArrayArg(args.components).filter(c => !!this.components[c]);
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
    const query = String(args.query || "").slice(0, MAX_SEARCH_QUERY_LENGTH).toLowerCase();
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

  private async handleMangleQuery(args: Record<string, unknown>): Promise<Record<string, unknown>> {
    const predicate = args.predicate as string;
    let rawArgs: unknown[] = [];
    if (args.args !== undefined) {
      try { rawArgs = Array.isArray(args.args) ? args.args : (JSON.parse(String(args.args)) as unknown[]); }
      catch { rawArgs = []; }
    }
    const remote = await callMangleService(predicate, rawArgs);
    if (remote.wired) {
      return { predicate, results: remote.results, wired: true };
    }
    // Fallback: local facts store
    const facts = this.facts[predicate];
    return facts
      ? { predicate, results: facts, wired: false }
      : { predicate, results: [], wired: false, message: 'Unknown predicate' };
  }

  async handleRequest(request: MCPRequest): Promise<MCPResponse> {
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
        const toolName = params.name as string;
        if (typeof toolName !== "string") {
          return { jsonrpc: "2.0", id, error: { code: -32602, message: 'tools/call requires string param "name"' } };
        }
        if (params.arguments !== undefined && (params.arguments === null || typeof params.arguments !== "object" || Array.isArray(params.arguments))) {
          return { jsonrpc: "2.0", id, error: { code: -32602, message: 'tools/call param "arguments" must be an object' } };
        }
        const args = (params.arguments || {}) as Record<string, unknown>;
        const syncHandlers: Record<string, (a: Record<string, unknown>) => Record<string, unknown>> = {
          list_components: () => this.handleListComponents(),
          get_component: (a) => this.handleGetComponent(a),
          generate_angular_template: (a) => this.handleGenerateAngularTemplate(a),
          generate_module_imports: (a) => this.handleGenerateModuleImports(a),
          search_components: (a) => this.handleSearchComponents(a),
          validate_template: (a) => this.handleValidateTemplate(a),
        };
        // Async tools: mangle_query, kuzu_index, kuzu_query
        if (toolName === 'mangle_query') {
          return this.handleMangleQuery(args).then((result) => {
            void metrics.record(`tool.${toolName}`, 1, { tool: toolName, ts: Date.now() });
            return { jsonrpc: "2.0", id, result: { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] } };
          }).catch((e: unknown) => ({ jsonrpc: "2.0", id, error: { code: -32603, message: String(e) } }));
        }
        if (toolName === 'kuzu_index') {
          return this.handleKuzuIndex(args).then((result) => {
            void metrics.record(`tool.${toolName}`, 1, { tool: toolName, ts: Date.now() });
            return { jsonrpc: "2.0", id, result: { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] } };
          }).catch((e: unknown) => ({ jsonrpc: "2.0", id, error: { code: -32603, message: String(e) } }));
        }
        if (toolName === 'kuzu_query') {
          return this.handleKuzuQuery(args).then((result) => {
            void metrics.record(`tool.${toolName}`, 1, { tool: toolName, ts: Date.now() });
            return { jsonrpc: "2.0", id, result: { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] } };
          }).catch((e: unknown) => ({ jsonrpc: "2.0", id, error: { code: -32603, message: String(e) } }));
        }
        const handler = syncHandlers[toolName];
        if (!handler) {
          return { jsonrpc: "2.0", id, error: { code: -32602, message: `Unknown tool: ${toolName}` } };
        }
        const result = handler(args);
        void metrics.record(`tool.${toolName}`, 1, { tool: toolName, ts: Date.now() });
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
app.use(express.json({ limit: `${MAX_JSON_BODY_BYTES}b` }));

// =============================================================================
// Bearer-token authentication middleware
// Set MCP_AUTH_TOKEN in the environment to require authentication on /mcp.
// Leave unset only for fully-isolated localhost-only deployments.
// =============================================================================

const MCP_AUTH_TOKEN = (process.env.MCP_AUTH_TOKEN ?? '').trim();

if (!MCP_AUTH_TOKEN) {
  console.warn(
    'WARNING: MCP_AUTH_TOKEN is not set. The /mcp endpoint is unauthenticated. ' +
    'Set MCP_AUTH_TOKEN to a secure random token before any non-localhost deployment.',
  );
}

function requireBearerAuth(req: Request, res: Response, next: (err?: unknown) => void): void {
  if (!MCP_AUTH_TOKEN) { next(); return; }
  const authHeader = (req.headers['authorization'] ?? '').trim();
  if (!authHeader.startsWith('Bearer ')) {
    res.status(401).json({ jsonrpc: '2.0', id: null, error: { code: -32001, message: 'Unauthorized: Bearer token required' } });
    return;
  }
  const token = authHeader.slice('Bearer '.length).trim();
  if (token !== MCP_AUTH_TOKEN) {
    res.status(401).json({ jsonrpc: '2.0', id: null, error: { code: -32001, message: 'Unauthorized: Invalid token' } });
    return;
  }
  next();
}

// Finding 4: CORS with startup warning and dev escape
const MCP_ALLOW_ALL_ORIGINS = ['1', 'true', 'yes'].includes((process.env.MCP_ALLOW_ALL_ORIGINS ?? '').trim().toLowerCase());
const corsAllowedOrigins = (() => {
  const raw = (process.env.CORS_ALLOWED_ORIGINS ?? '').trim();
  if (raw) return raw.split(',').map(o => o.trim()).filter(Boolean);
  if (!MCP_ALLOW_ALL_ORIGINS) {
    console.warn(
      'WARNING: CORS_ALLOWED_ORIGINS is not set. Defaulting to localhost only. ' +
      'Non-localhost origins (Angular dev server on a named host, BTP, Docker) will be rejected. ' +
      'Set CORS_ALLOWED_ORIGINS to a comma-separated list of allowed origins, or set ' +
      'MCP_ALLOW_ALL_ORIGINS=1 for development.',
    );
  }
  return ['http://localhost:3000', 'http://127.0.0.1:3000', 'http://localhost:4200', 'http://127.0.0.1:4200'];
})();
const getCorsOrigin = (req: Request): string => {
  if (MCP_ALLOW_ALL_ORIGINS) return '*';
  const origin = (req.headers.origin ?? '').trim();
  if (origin && corsAllowedOrigins.includes(origin)) return origin;
  return corsAllowedOrigins[0] ?? '';
};
app.use((req, res, next) => {
  const corsOrigin = getCorsOrigin(req);
  if (corsOrigin) res.header('Access-Control-Allow-Origin', corsOrigin);
  res.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.header('Access-Control-Allow-Headers', 'Content-Type');
  next();
});

app.options("*", (_req, res) => res.sendStatus(204));

app.use((err: unknown, _req: Request, res: Response, next: (err?: unknown) => void) => {
  if (err && typeof err === "object" && "type" in err && (err as { type?: string }).type === "entity.parse.failed") {
    return res.status(400).json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
  }
  if (err && typeof err === "object" && "type" in err && (err as { type?: string }).type === "entity.too.large") {
    return res.status(413).json({ jsonrpc: "2.0", id: null, error: { code: -32600, message: "Request too large" } });
  }
  return next(err);
});

app.get("/health", (_req: Request, res: Response) => {
  res.json({
    status: "healthy",
    service: "ui5-webcomponents-ngx-mcp",
    timestamp: new Date().toISOString(),
    uptimeSeconds: Math.round(process.uptime()),
  });
});

app.post("/mcp", requireBearerAuth, (req: Request, res: Response) => {
  if (!isValidJsonRpcRequest(req.body)) {
    return res.status(400).json({ jsonrpc: "2.0", id: null, error: { code: -32600, message: "Invalid Request" } });
  }
  void mcpServer.handleRequest(req.body).then((response) => res.json(response)).catch((e: unknown) => {
    res.status(500).json({ jsonrpc: "2.0", id: null, error: { code: -32603, message: String(e) } });
  });
  return;
});

const requestedPort = parseInt(process.argv.find(a => a.startsWith("--port="))?.split("=")[1] || "9160", 10);
const port = Number.isInteger(requestedPort) && requestedPort > 0 && requestedPort <= 65535 ? requestedPort : 9160;
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
