// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * PalClient — thin MCP JSON-RPC client for ai-core-pal.
 *
 * Calls the 13 PAL tools exposed by ai-core-pal/zig/src/mcp/mcp.zig:
 *   pal-catalog, pal-execute, pal-spec, pal-sql,
 *   schema-explore, describe-table, schema-refresh,
 *   hybrid-search, llm-query, …
 */

import type { A2UiSchema } from './event-types';

// =============================================================================
// Types
// =============================================================================

export interface PalHybridSearchResult {
  algorithm: string;
  description: string;
  score: number;
  category?: string;
}

export interface PalExecuteResult {
  sql: string;
  algorithm: string;
  parameters: Record<string, unknown>;
}

export interface PalTableColumn {
  name: string;
  type: string;
  nullable: boolean;
  primaryKey: boolean;
}

export interface PalTableInfo {
  name: string;
  columns: PalTableColumn[];
}

export interface PalCatalogEntry {
  name: string;
  category: string;
  description: string;
  tags: string[];
}

// =============================================================================
// MCP JSON-RPC helpers
// =============================================================================

interface McpRequest {
  jsonrpc: '2.0';
  id: number;
  method: string;
  params: {
    name: string;
    arguments: Record<string, unknown>;
  };
}

interface McpResponse<T = unknown> {
  jsonrpc: '2.0';
  id: number;
  result?: { content: Array<{ type: string; text: string }>; isError?: boolean };
  error?: { code: number; message: string };
}

// =============================================================================
// PalClient
// =============================================================================

export class PalClient {
  private readonly endpoint: string;
  private requestId = 0;

  constructor(endpoint: string = 'http://localhost:8084/mcp') {
    this.endpoint = endpoint;
  }

  // ---------------------------------------------------------------------------
  // Core tool callers
  // ---------------------------------------------------------------------------

  /** Search PAL algorithms using hybrid vector + keyword search with RRF. */
  async hybridSearch(query: string, maxResults = 5): Promise<PalHybridSearchResult[]> {
    const raw = await this.callTool('hybrid-search', { query, max_results: maxResults });
    try {
      return JSON.parse(raw) as PalHybridSearchResult[];
    } catch {
      return [];
    }
  }

  /** Generate a HANA SQL CALL script for a PAL algorithm. */
  async palExecute(algorithm: string, table?: string, params?: Record<string, unknown>): Promise<PalExecuteResult> {
    const args: Record<string, unknown> = { algorithm };
    if (table) args['table'] = table;
    if (params) args['params'] = params;
    const raw = await this.callTool('pal-execute', args);
    try {
      return JSON.parse(raw) as PalExecuteResult;
    } catch {
      return { sql: raw, algorithm, parameters: params ?? {} };
    }
  }

  /** Read the ODPS YAML specification for a PAL algorithm. */
  async palSpec(algorithm: string): Promise<string> {
    return this.callTool('pal-spec', { algorithm });
  }

  /** Get the SQL template for a PAL algorithm. */
  async palSql(algorithm: string): Promise<string> {
    return this.callTool('pal-sql', { algorithm });
  }

  /** List all tables from the connected HANA schema. */
  async schemaExplore(): Promise<string[]> {
    const raw = await this.callTool('schema-explore', {});
    try {
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed : [raw];
    } catch {
      return [raw];
    }
  }

  /** Describe a specific HANA table — columns, types, PKs. */
  async describeTable(name: string): Promise<PalTableInfo> {
    const raw = await this.callTool('describe-table', { table: name });
    try {
      return JSON.parse(raw) as PalTableInfo;
    } catch {
      return { name, columns: [] };
    }
  }

  /** Refresh the schema cache from HANA system tables. */
  async schemaRefresh(): Promise<void> {
    await this.callTool('schema-refresh', {});
  }

  /** List or search the 162 PAL algorithms by category / tag. */
  async palCatalog(filter?: { category?: string; tag?: string; query?: string }): Promise<PalCatalogEntry[]> {
    const raw = await this.callTool('pal-catalog', filter ?? {});
    try {
      return JSON.parse(raw) as PalCatalogEntry[];
    } catch {
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // High-level helper: generate a ui5-table A2UiSchema from PAL execute result
  // ---------------------------------------------------------------------------

  /**
   * Run a PAL algorithm and wrap the result as a ui5-table A2UiSchema node
   * suitable for rendering in <genui-streaming-outlet>.
   */
  async generatePalTableSchema(
    userQuery: string,
    table?: string
  ): Promise<A2UiSchema> {
    // 1. Find the most relevant algorithm
    const hits = await this.hybridSearch(userQuery, 3);
    const bestAlgorithm = hits[0]?.algorithm ?? 'pal-forecast';

    // 2. Generate PAL SQL
    const result = await this.palExecute(bestAlgorithm, table);

    // 3. Wrap as A2UiSchema ui5-table
    return {
      component: 'ui5-panel',
      props: { headerText: `PAL: ${bestAlgorithm}` },
      children: [
        {
          component: 'ui5-text',
          props: {
            text: `Generated SQL for ${bestAlgorithm}:`,
          },
        },
        {
          component: 'ui5-table',
          props: {
            columns: ['Step', 'SQL'],
          },
          children: result.sql.split('\n').filter(Boolean).map((line, i) => ({
            component: 'ui5-table-row',
            props: {},
            children: [
              { component: 'ui5-table-cell', props: { text: String(i + 1) } },
              { component: 'ui5-table-cell', props: { text: line } },
            ],
          })),
        },
      ],
    } as unknown as A2UiSchema;
  }

  // ---------------------------------------------------------------------------
  // Internal: MCP JSON-RPC call
  // ---------------------------------------------------------------------------

  private async callTool(toolName: string, args: Record<string, unknown>): Promise<string> {
    const id = ++this.requestId;
    const body: McpRequest = {
      jsonrpc: '2.0',
      id,
      method: 'tools/call',
      params: { name: toolName, arguments: args },
    };

    const response = await fetch(this.endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });

    if (!response.ok) {
      throw new Error(`PalClient: HTTP ${response.status} calling tool '${toolName}'`);
    }

    const json = (await response.json()) as McpResponse;

    if (json.error) {
      throw new Error(`PalClient: MCP error ${json.error.code}: ${json.error.message}`);
    }

    const content = json.result?.content ?? [];
    const text = content.find(c => c.type === 'text')?.text ?? '';

    if (json.result?.isError) {
      throw new Error(`PalClient: Tool '${toolName}' returned error: ${text}`);
    }

    return text;
  }
}
