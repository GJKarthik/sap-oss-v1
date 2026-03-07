/**
 * PalClient — thin MCP JSON-RPC client for ai-core-pal.
 *
 * Calls the 13 PAL tools exposed by ai-core-pal/zig/src/mcp/mcp.zig:
 *   pal-catalog, pal-execute, pal-spec, pal-sql,
 *   schema-explore, describe-table, schema-refresh,
 *   hybrid-search, llm-query, …
 */
import type { A2UiSchema } from './event-types';
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
export declare class PalClient {
    private readonly endpoint;
    private requestId;
    constructor(endpoint?: string);
    /** Search PAL algorithms using hybrid vector + keyword search with RRF. */
    hybridSearch(query: string, maxResults?: number): Promise<PalHybridSearchResult[]>;
    /** Generate a HANA SQL CALL script for a PAL algorithm. */
    palExecute(algorithm: string, table?: string, params?: Record<string, unknown>): Promise<PalExecuteResult>;
    /** Read the ODPS YAML specification for a PAL algorithm. */
    palSpec(algorithm: string): Promise<string>;
    /** Get the SQL template for a PAL algorithm. */
    palSql(algorithm: string): Promise<string>;
    /** List all tables from the connected HANA schema. */
    schemaExplore(): Promise<string[]>;
    /** Describe a specific HANA table — columns, types, PKs. */
    describeTable(name: string): Promise<PalTableInfo>;
    /** Refresh the schema cache from HANA system tables. */
    schemaRefresh(): Promise<void>;
    /** List or search the 162 PAL algorithms by category / tag. */
    palCatalog(filter?: {
        category?: string;
        tag?: string;
        query?: string;
    }): Promise<PalCatalogEntry[]>;
    /**
     * Run a PAL algorithm and wrap the result as a ui5-table A2UiSchema node
     * suitable for rendering in <genui-streaming-outlet>.
     */
    generatePalTableSchema(userQuery: string, table?: string): Promise<A2UiSchema>;
    private callTool;
}
//# sourceMappingURL=pal-client.d.ts.map