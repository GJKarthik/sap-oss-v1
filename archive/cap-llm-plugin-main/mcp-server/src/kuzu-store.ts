// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * KùzuDB Graph-RAG store for cap-llm-plugin MCP server.
 *
 * Schema:
 *   Nodes  : CapService, LlmDeployment, RagTable
 *   Edges  : SERVED_BY  (CapService → LlmDeployment)
 *            USES_TABLE (CapService → RagTable)
 *            ROUTES_TO  (CapService → CapService)
 *
 * Gracefully degrades when the `kuzu` npm package is not installed.
 */

export interface GraphContextEntry {
  relation: string;
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// Kuzu type shims (resolved at runtime; absent when package is missing)
// ---------------------------------------------------------------------------

interface KuzuDatabase {
  constructor: new (path: string) => KuzuDatabase;
}

interface KuzuQueryResult {
  getColumnNames(): string[];
  hasNext(): boolean;
  getNext(): unknown[];
}

interface KuzuConnection {
  execute(cypher: string, params?: Record<string, unknown>): Promise<KuzuQueryResult>;
}

// ---------------------------------------------------------------------------
// KuzuStore
// ---------------------------------------------------------------------------

export class KuzuStore {
  private dbPath: string;
  private db: KuzuDatabase | null = null;
  private conn: KuzuConnection | null = null;
  private _available = false;
  private _schemaReady = false;

  constructor(dbPath = '.kuzu-cap-llm') {
    this.dbPath = dbPath;
    this._init();
  }

  private _init(): void {
    try {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const kuzu = require('kuzu') as {
        Database: new (path: string) => KuzuDatabase;
        Connection: new (db: KuzuDatabase) => KuzuConnection;
      };
      this.db = new kuzu.Database(this.dbPath);
      this.conn = new kuzu.Connection(this.db);
      this._available = true;
    } catch {
      this._available = false;
    }
  }

  available(): boolean {
    return this._available;
  }

  async ensureSchema(): Promise<void> {
    if (!this._available || !this.conn || this._schemaReady) return;

    const ddl: string[] = [
      // Node tables
      `CREATE NODE TABLE IF NOT EXISTS CapService (
         serviceId   STRING,
         serviceName STRING,
         serviceType STRING,
         dataClass   STRING,
         PRIMARY KEY (serviceId)
       )`,
      `CREATE NODE TABLE IF NOT EXISTS LlmDeployment (
         deploymentId  STRING,
         modelName     STRING,
         resourceGroup STRING,
         status        STRING,
         PRIMARY KEY (deploymentId)
       )`,
      `CREATE NODE TABLE IF NOT EXISTS RagTable (
         tableId     STRING,
         tableName   STRING,
         description STRING,
         schema      STRING,
         PRIMARY KEY (tableId)
       )`,
      // Relationship tables
      `CREATE REL TABLE IF NOT EXISTS SERVED_BY (
         FROM CapService TO LlmDeployment
       )`,
      `CREATE REL TABLE IF NOT EXISTS USES_TABLE (
         FROM CapService TO RagTable
       )`,
      `CREATE REL TABLE IF NOT EXISTS ROUTES_TO (
         FROM CapService TO CapService
       )`,
    ];

    for (const stmt of ddl) {
      await this.conn.execute(stmt);
    }
    this._schemaReady = true;
  }

  // ---------------------------------------------------------------------------
  // Upsert helpers
  // ---------------------------------------------------------------------------

  async upsertService(
    serviceId: string,
    serviceName: string,
    serviceType: string,
    dataClass: string,
  ): Promise<void> {
    if (!this._available || !this.conn) return;
    await this.conn.execute(
      `MERGE (s:CapService {serviceId: $id})
       ON MATCH SET s.serviceName = $name, s.serviceType = $type, s.dataClass = $dc
       ON CREATE SET s.serviceName = $name, s.serviceType = $type, s.dataClass = $dc`,
      { id: serviceId, name: serviceName, type: serviceType, dc: dataClass },
    );
  }

  async upsertDeployment(
    deploymentId: string,
    modelName: string,
    resourceGroup: string,
    status: string,
  ): Promise<void> {
    if (!this._available || !this.conn) return;
    await this.conn.execute(
      `MERGE (d:LlmDeployment {deploymentId: $id})
       ON MATCH SET d.modelName = $model, d.resourceGroup = $rg, d.status = $status
       ON CREATE SET d.modelName = $model, d.resourceGroup = $rg, d.status = $status`,
      { id: deploymentId, model: modelName, rg: resourceGroup, status },
    );
  }

  async upsertRagTable(
    tableId: string,
    tableName: string,
    description: string,
    schema: string,
  ): Promise<void> {
    if (!this._available || !this.conn) return;
    await this.conn.execute(
      `MERGE (t:RagTable {tableId: $id})
       ON MATCH SET t.tableName = $name, t.description = $desc, t.schema = $schema
       ON CREATE SET t.tableName = $name, t.description = $desc, t.schema = $schema`,
      { id: tableId, name: tableName, desc: description, schema },
    );
  }

  // ---------------------------------------------------------------------------
  // Linking helpers
  // ---------------------------------------------------------------------------

  async linkServiceDeployment(serviceId: string, deploymentId: string): Promise<void> {
    if (!this._available || !this.conn) return;
    await this.conn.execute(
      `MATCH (s:CapService {serviceId: $sid}), (d:LlmDeployment {deploymentId: $did})
       MERGE (s)-[:SERVED_BY]->(d)`,
      { sid: serviceId, did: deploymentId },
    );
  }

  async linkServiceTable(serviceId: string, tableId: string): Promise<void> {
    if (!this._available || !this.conn) return;
    await this.conn.execute(
      `MATCH (s:CapService {serviceId: $sid}), (t:RagTable {tableId: $tid})
       MERGE (s)-[:USES_TABLE]->(t)`,
      { sid: serviceId, tid: tableId },
    );
  }

  async linkServiceRoute(fromServiceId: string, toServiceId: string): Promise<void> {
    if (!this._available || !this.conn) return;
    await this.conn.execute(
      `MATCH (a:CapService {serviceId: $from}), (b:CapService {serviceId: $to})
       MERGE (a)-[:ROUTES_TO]->(b)`,
      { from: fromServiceId, to: toServiceId },
    );
  }

  // ---------------------------------------------------------------------------
  // Query helpers
  // ---------------------------------------------------------------------------

  async runQuery(cypher: string, params: Record<string, unknown> = {}): Promise<Record<string, unknown>[]> {
    if (!this._available || !this.conn) return [];
    try {
      const result = await this.conn.execute(cypher, params);
      const cols = result.getColumnNames();
      const rows: Record<string, unknown>[] = [];
      while (result.hasNext()) {
        const values = result.getNext();
        const row: Record<string, unknown> = {};
        cols.forEach((col, i) => { row[col] = values[i]; });
        rows.push(row);
      }
      return rows;
    } catch (err) {
      console.error('KùzuDB query failed:', (err as Error).message);
      return [];
    }
  }

  async getServiceContext(serviceId: string): Promise<GraphContextEntry[]> {
    if (!this._available) return [];
    const rows = await this.runQuery(
      `MATCH (s:CapService {serviceId: $id})-[:SERVED_BY]->(d:LlmDeployment)
       RETURN d.deploymentId AS deploymentId, d.modelName AS modelName,
              d.resourceGroup AS resourceGroup, d.status AS status,
              'served_by' AS relation`,
      { id: serviceId },
    );
    return rows as GraphContextEntry[];
  }

  async getRagContext(tableId: string): Promise<GraphContextEntry[]> {
    if (!this._available) return [];
    const rows = await this.runQuery(
      `MATCH (s:CapService)-[:USES_TABLE]->(t:RagTable {tableId: $id})
       RETURN s.serviceId AS serviceId, s.serviceName AS serviceName,
              s.serviceType AS serviceType, 'uses_table' AS relation`,
      { id: tableId },
    );
    return rows as GraphContextEntry[];
  }
}

// ---------------------------------------------------------------------------
// Singleton
// ---------------------------------------------------------------------------

let _instance: KuzuStore | null = null;

export function getKuzuStore(): KuzuStore {
  if (!_instance) {
    _instance = new KuzuStore(process.env.KUZU_DB_PATH || '.kuzu-cap-llm');
  }
  return _instance;
}

export function _resetKuzuStore(): void {
  _instance = null;
}
