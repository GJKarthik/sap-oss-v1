// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * KùzuDB Graph Store for SAP AI SDK MCP Server.
 *
 * Maintains a property graph of AI SDK inference entities used to enrich
 * deployment-listing responses with model and orchestration context.
 *
 * Schema
 * ------
 * Node tables
 *   AiDeployment         – an AI Core deployed model endpoint
 *   AiModel              – a foundation model (GPT-4, Claude, etc.)
 *   OrchestrationScenario – an orchestration pipeline scenario
 *
 * Relationship tables
 *   USES_MODEL       – AiDeployment → AiModel
 *   RUNS_SCENARIO    – AiDeployment → OrchestrationScenario
 *   ROUTES_TO        – OrchestrationScenario → AiDeployment
 *
 * Usage
 * -----
 *   import { getKuzuStore } from './kuzu-store';
 *
 *   const store = getKuzuStore();
 *   await store.ensureSchema();
 *   await store.upsertDeployment('dep-abc', 'gpt-4', 'default', 'RUNNING');
 *   await store.upsertModel('gpt-4', 'azure-openai', 'Microsoft', 'chat,embed');
 *   await store.linkDeploymentModel('dep-abc', 'gpt-4');
 *   const ctx = await store.getDeploymentContext('dep-abc');
 */

/* eslint-disable @typescript-eslint/no-explicit-any */

const KUZU_DB_PATH = (process.env['KUZU_DB_PATH'] ?? ':memory:').trim();

let _singleton: KuzuStore | null = null;

export function getKuzuStore(): KuzuStore {
  if (!_singleton) {
    _singleton = new KuzuStore(KUZU_DB_PATH);
  }
  return _singleton;
}

/** Reset the singleton (test use only). */
export function _resetKuzuStore(): void {
  _singleton = null;
}

export interface GraphContextEntry {
  relation: string;
  [key: string]: unknown;
}

export class KuzuStore {
  private dbPath: string;
  private db: any = null;
  private conn: any = null;
  private _available = false;
  private _schemaReady = false;

  constructor(dbPath: string = ':memory:') {
    this.dbPath = dbPath;
    this._available = this._initDb();
  }

  // ---------------------------------------------------------------------------
  // M1 – Initialisation
  // ---------------------------------------------------------------------------

  private _initDb(): boolean {
    try {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const kuzu = require('kuzu');
      this.db = new kuzu.Database(this.dbPath);
      this.conn = new kuzu.Connection(this.db);
      return true;
    } catch (err: any) {
      const msg: string = String(err?.message ?? err ?? '');
      if (msg.includes('Cannot find module') || msg.includes('MODULE_NOT_FOUND')) {
        process.stderr.write(
          "WARNING: 'kuzu' npm package not installed; graph-RAG features disabled. " +
          "Add \"kuzu\": \"^0.7.0\" to packages/mcp-server/package.json to enable.\n",
        );
      } else {
        process.stderr.write(`WARNING: KùzuDB init failed: ${msg.slice(0, 120)}\n`);
      }
      return false;
    }
  }

  available(): boolean {
    return this._available;
  }

  async ensureSchema(): Promise<void> {
    if (!this._available || this._schemaReady) return;

    const stmts = [
      // Node: an AI Core deployment
      `CREATE NODE TABLE IF NOT EXISTS AiDeployment (
        deploymentId  STRING,
        modelName     STRING,
        resourceGroup STRING,
        status        STRING,
        PRIMARY KEY (deploymentId)
      )`,
      // Node: a foundation model
      `CREATE NODE TABLE IF NOT EXISTS AiModel (
        modelId      STRING,
        modelFamily  STRING,
        provider     STRING,
        capabilities STRING,
        PRIMARY KEY (modelId)
      )`,
      // Node: an orchestration scenario
      `CREATE NODE TABLE IF NOT EXISTS OrchestrationScenario (
        scenarioId  STRING,
        name        STRING,
        description STRING,
        dataClass   STRING,
        PRIMARY KEY (scenarioId)
      )`,
      // Relationship: deployment uses a model
      `CREATE REL TABLE IF NOT EXISTS USES_MODEL (
        FROM AiDeployment TO AiModel
      )`,
      // Relationship: deployment handles a scenario
      `CREATE REL TABLE IF NOT EXISTS RUNS_SCENARIO (
        FROM AiDeployment TO OrchestrationScenario
      )`,
      // Relationship: scenario resolved to deployment
      `CREATE REL TABLE IF NOT EXISTS ROUTES_TO (
        FROM OrchestrationScenario TO AiDeployment
      )`,
    ];

    for (const stmt of stmts) {
      try {
        await this._exec(stmt);
      } catch (err: any) {
        const msg = String(err?.message ?? '');
        if (!msg.includes('already exists')) {
          process.stderr.write(`KùzuDB schema stmt skipped: ${msg.slice(0, 80)}\n`);
        }
      }
    }
    this._schemaReady = true;
  }

  // ---------------------------------------------------------------------------
  // Low-level query helper
  // ---------------------------------------------------------------------------

  private async _exec(cypher: string, params?: Record<string, unknown>): Promise<any> {
    if (params && Object.keys(params).length > 0) {
      return this.conn.execute(cypher, params);
    }
    return this.conn.execute(cypher);
  }

  // ---------------------------------------------------------------------------
  // M2 helpers – upsert operations called by kuzu_index tool
  // ---------------------------------------------------------------------------

  async upsertDeployment(
    deploymentId: string,
    modelName = '',
    resourceGroup = 'default',
    status = 'unknown',
  ): Promise<void> {
    if (!this._available) return;
    try {
      await this._exec(
        'MERGE (d:AiDeployment {deploymentId: $id}) ' +
        'SET d.modelName = $model, d.resourceGroup = $rg, d.status = $status',
        { id: deploymentId, model: modelName, rg: resourceGroup, status },
      );
    } catch {
      try {
        await this._exec(
          'CREATE (d:AiDeployment {deploymentId: $id, modelName: $model, ' +
          'resourceGroup: $rg, status: $status})',
          { id: deploymentId, model: modelName, rg: resourceGroup, status },
        );
      } catch (err2: any) {
        process.stderr.write(`upsertDeployment failed for ${deploymentId}: ${err2?.message}\n`);
      }
    }
  }

  async upsertModel(
    modelId: string,
    modelFamily = '',
    provider = '',
    capabilities = '',
  ): Promise<void> {
    if (!this._available) return;
    try {
      await this._exec(
        'MERGE (m:AiModel {modelId: $id}) ' +
        'SET m.modelFamily = $family, m.provider = $provider, m.capabilities = $caps',
        { id: modelId, family: modelFamily, provider, caps: capabilities },
      );
    } catch {
      try {
        await this._exec(
          'CREATE (m:AiModel {modelId: $id, modelFamily: $family, ' +
          'provider: $provider, capabilities: $caps})',
          { id: modelId, family: modelFamily, provider, caps: capabilities },
        );
      } catch (err2: any) {
        process.stderr.write(`upsertModel failed for ${modelId}: ${err2?.message}\n`);
      }
    }
  }

  async upsertScenario(
    scenarioId: string,
    name = '',
    description = '',
    dataClass = 'internal',
  ): Promise<void> {
    if (!this._available) return;
    try {
      await this._exec(
        'MERGE (s:OrchestrationScenario {scenarioId: $id}) ' +
        'SET s.name = $name, s.description = $desc, s.dataClass = $dc',
        { id: scenarioId, name, desc: description, dc: dataClass },
      );
    } catch {
      try {
        await this._exec(
          'CREATE (s:OrchestrationScenario {scenarioId: $id, name: $name, ' +
          'description: $desc, dataClass: $dc})',
          { id: scenarioId, name, desc: description, dc: dataClass },
        );
      } catch (err2: any) {
        process.stderr.write(`upsertScenario failed for ${scenarioId}: ${err2?.message}\n`);
      }
    }
  }

  async linkDeploymentModel(deploymentId: string, modelId: string): Promise<void> {
    if (!this._available) return;
    try {
      await this._exec(
        'MATCH (d:AiDeployment {deploymentId: $did}), (m:AiModel {modelId: $mid}) ' +
        'CREATE (d)-[:USES_MODEL]->(m)',
        { did: deploymentId, mid: modelId },
      );
    } catch (err: any) {
      process.stderr.write(`linkDeploymentModel failed ${deploymentId}->${modelId}: ${err?.message}\n`);
    }
  }

  async linkDeploymentScenario(deploymentId: string, scenarioId: string): Promise<void> {
    if (!this._available) return;
    try {
      await this._exec(
        'MATCH (d:AiDeployment {deploymentId: $did}), (s:OrchestrationScenario {scenarioId: $sid}) ' +
        'CREATE (d)-[:RUNS_SCENARIO]->(s)',
        { did: deploymentId, sid: scenarioId },
      );
    } catch (err: any) {
      process.stderr.write(`linkDeploymentScenario failed ${deploymentId}->${scenarioId}: ${err?.message}\n`);
    }
  }

  async linkScenarioDeployment(scenarioId: string, deploymentId: string): Promise<void> {
    if (!this._available) return;
    try {
      await this._exec(
        'MATCH (s:OrchestrationScenario {scenarioId: $sid}), (d:AiDeployment {deploymentId: $did}) ' +
        'CREATE (s)-[:ROUTES_TO]->(d)',
        { sid: scenarioId, did: deploymentId },
      );
    } catch (err: any) {
      process.stderr.write(`linkScenarioDeployment failed ${scenarioId}->${deploymentId}: ${err?.message}\n`);
    }
  }

  // ---------------------------------------------------------------------------
  // M3 helper – raw Cypher query used by kuzu_query tool
  // ---------------------------------------------------------------------------

  async runQuery(cypher: string, params?: Record<string, unknown>): Promise<GraphContextEntry[]> {
    if (!this._available) return [];
    try {
      const result = await this._exec(cypher, params ?? {});
      const colNames: string[] = result.getColumnNames?.() ?? [];
      const rows: GraphContextEntry[] = [];
      while (result.hasNext?.()) {
        const row: unknown[] = result.getNext();
        const entry: GraphContextEntry = { relation: '' };
        colNames.forEach((col, i) => { entry[col] = row[i]; });
        rows.push(entry);
      }
      return rows;
    } catch (err: any) {
      process.stderr.write(`KùzuDB query failed: ${err?.message}\n`);
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // M4 helpers – graph context enrichment for list_deployments
  // ---------------------------------------------------------------------------

  /** Return model and scenario context for a given deploymentId. */
  async getDeploymentContext(deploymentId: string): Promise<GraphContextEntry[]> {
    if (!this._available) return [];

    const modelRows = await this.runQuery(
      'MATCH (d:AiDeployment {deploymentId: $id})-[:USES_MODEL]->(m:AiModel) ' +
      'RETURN m.modelId AS modelId, m.modelFamily AS modelFamily, ' +
      'm.provider AS provider, m.capabilities AS capabilities, \'uses_model\' AS relation LIMIT 5',
      { id: deploymentId },
    );

    const scenarioRows = await this.runQuery(
      'MATCH (d:AiDeployment {deploymentId: $id})-[:RUNS_SCENARIO]->(s:OrchestrationScenario) ' +
      'RETURN s.scenarioId AS scenarioId, s.name AS name, ' +
      's.dataClass AS dataClass, \'runs_scenario\' AS relation LIMIT 5',
      { id: deploymentId },
    );

    return [...modelRows, ...scenarioRows];
  }

  /** Return deployments and routing context for a given scenarioId. */
  async getScenarioContext(scenarioId: string): Promise<GraphContextEntry[]> {
    if (!this._available) return [];

    const deploymentRows = await this.runQuery(
      'MATCH (s:OrchestrationScenario {scenarioId: $id})-[:ROUTES_TO]->(d:AiDeployment) ' +
      'RETURN d.deploymentId AS deploymentId, d.modelName AS modelName, ' +
      'd.status AS status, \'routes_to\' AS relation LIMIT 10',
      { id: scenarioId },
    );

    return deploymentRows;
  }
}
