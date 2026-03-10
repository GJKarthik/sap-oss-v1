// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * KùzuDB Graph Store for UI5 Web Components Angular MCP Server.
 *
 * Maintains a property graph of UI5 component relationships used to enrich
 * template-generation responses with related-component and co-usage context.
 *
 * Schema
 * ------
 * Node tables
 *   Ui5Component   – a UI5 Web Component (tag name is the primary key)
 *   AngularModule  – an Angular NgModule that exposes components
 *   ComponentSlot  – a named slot exposed by a component
 *
 * Relationship tables
 *   BELONGS_TO     – Ui5Component → AngularModule
 *   HAS_SLOT       – Ui5Component → ComponentSlot
 *   CO_USED_WITH   – Ui5Component → Ui5Component (template co-usage)
 *
 * Usage
 * -----
 *   import { getKuzuStore } from './kuzu-store';
 *
 *   const store = getKuzuStore();
 *   await store.ensureSchema();
 *   await store.upsertComponent('ui5-button', 'Ui5ButtonModule', ['default', 'icon']);
 *   await store.linkCoUsage('ui5-button', 'ui5-dialog');
 *   const ctx = await store.getComponentContext('ui5-button');
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
    this._available = this.initDb();
  }

  // ---------------------------------------------------------------------------
  // M1 – Initialisation
  // ---------------------------------------------------------------------------

  private initDb(): boolean {
    try {
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const kuzu = require('kuzu') as { Database: new (p: string) => any; Connection: new (db: any) => any };
      this.db = new kuzu.Database(this.dbPath);
      this.conn = new kuzu.Connection(this.db);
      console.info(`INFO: KùzuDB initialised at '${this.dbPath}'`);
      return true;
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      if (msg.includes('Cannot find module')) {
        console.warn(
          'WARNING: kuzu npm package not installed; graph-RAG features disabled. ' +
          "Add 'kuzu' to mcp-server/package.json dependencies to enable.",
        );
      } else {
        console.warn(`WARNING: KùzuDB init failed: ${msg}`);
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
      // Node: a UI5 web component
      `CREATE NODE TABLE IF NOT EXISTS Ui5Component (
        tag_name      STRING,
        angular_module STRING,
        npm_module    STRING,
        PRIMARY KEY (tag_name)
      )`,
      // Node: an Angular NgModule
      `CREATE NODE TABLE IF NOT EXISTS AngularModule (
        module_name STRING,
        package     STRING,
        PRIMARY KEY (module_name)
      )`,
      // Node: a named slot of a component
      `CREATE NODE TABLE IF NOT EXISTS ComponentSlot (
        slot_id   STRING,
        tag_name  STRING,
        slot_name STRING,
        PRIMARY KEY (slot_id)
      )`,
      // Relationship: component belongs to Angular module
      `CREATE REL TABLE IF NOT EXISTS BELONGS_TO (
        FROM Ui5Component TO AngularModule
      )`,
      // Relationship: component exposes a slot
      `CREATE REL TABLE IF NOT EXISTS HAS_SLOT (
        FROM Ui5Component TO ComponentSlot
      )`,
      // Relationship: two components frequently appear together in templates
      `CREATE REL TABLE IF NOT EXISTS CO_USED_WITH (
        FROM Ui5Component TO Ui5Component,
        weight INTEGER
      )`,
    ];
    for (const stmt of stmts) {
      try {
        await this.exec(stmt);
      } catch (e: unknown) {
        // IF NOT EXISTS makes this idempotent; log debug only
        const msg = e instanceof Error ? e.message : String(e);
        if (!msg.includes('already exists')) {
          console.debug(`KùzuDB schema stmt skipped (${msg.slice(0, 80)})`);
        }
      }
    }
    this._schemaReady = true;
  }

  // ---------------------------------------------------------------------------
  // Low-level query helper
  // ---------------------------------------------------------------------------

  private async exec(cypher: string, params: Record<string, unknown> = {}): Promise<any> {
    return new Promise((resolve, reject) => {
      try {
        const result = this.conn.execute(cypher, params);
        resolve(result);
      } catch (e) {
        reject(e);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // M2 helpers – upsert operations called by kuzu_index tool
  // ---------------------------------------------------------------------------

  async upsertComponent(
    tagName: string,
    angularModule: string,
    npmModule = '',
    slots: string[] = [],
  ): Promise<void> {
    if (!this._available) return;
    // Upsert Ui5Component node
    try {
      await this.exec(
        'MERGE (c:Ui5Component {tag_name: $tag}) ' +
        'SET c.angular_module = $mod, c.npm_module = $npm',
        { tag: tagName, mod: angularModule, npm: npmModule },
      );
    } catch {
      try {
        await this.exec(
          'CREATE (c:Ui5Component {tag_name: $tag, angular_module: $mod, npm_module: $npm})',
          { tag: tagName, mod: angularModule, npm: npmModule },
        );
      } catch (e2) {
        console.debug(`upsertComponent node failed for ${tagName}: ${String(e2)}`);
      }
    }
    // Upsert AngularModule node
    try {
      await this.exec(
        'MERGE (m:AngularModule {module_name: $mod})',
        { mod: angularModule },
      );
    } catch {
      try {
        await this.exec(
          'CREATE (m:AngularModule {module_name: $mod, package: $pkg})',
          { mod: angularModule, pkg: '@ui5/webcomponents-ngx' },
        );
      } catch (e2) {
        console.debug(`upsertComponent module failed for ${angularModule}: ${String(e2)}`);
      }
    }
    // BELONGS_TO edge
    try {
      await this.exec(
        'MATCH (c:Ui5Component {tag_name: $tag}), (m:AngularModule {module_name: $mod}) ' +
        'CREATE (c)-[:BELONGS_TO]->(m)',
        { tag: tagName, mod: angularModule },
      );
    } catch (e) {
      console.debug(`BELONGS_TO edge failed ${tagName}->${angularModule}: ${String(e)}`);
    }
    // Slot nodes + HAS_SLOT edges
    for (const slotName of slots) {
      const slotId = `${tagName}::${slotName}`;
      try {
        await this.exec(
          'MERGE (s:ComponentSlot {slot_id: $sid}) SET s.tag_name = $tag, s.slot_name = $slot',
          { sid: slotId, tag: tagName, slot: slotName },
        );
      } catch {
        try {
          await this.exec(
            'CREATE (s:ComponentSlot {slot_id: $sid, tag_name: $tag, slot_name: $slot})',
            { sid: slotId, tag: tagName, slot: slotName },
          );
        } catch (e2) {
          console.debug(`slot node failed ${slotId}: ${String(e2)}`);
        }
      }
      try {
        await this.exec(
          'MATCH (c:Ui5Component {tag_name: $tag}), (s:ComponentSlot {slot_id: $sid}) ' +
          'CREATE (c)-[:HAS_SLOT]->(s)',
          { tag: tagName, sid: slotId },
        );
      } catch (e) {
        console.debug(`HAS_SLOT edge failed ${tagName}->${slotId}: ${String(e)}`);
      }
    }
  }

  async linkCoUsage(tagA: string, tagB: string, weight = 1): Promise<void> {
    if (!this._available) return;
    try {
      await this.exec(
        'MATCH (a:Ui5Component {tag_name: $a}), (b:Ui5Component {tag_name: $b}) ' +
        'CREATE (a)-[:CO_USED_WITH {weight: $w}]->(b)',
        { a: tagA, b: tagB, w: weight },
      );
    } catch (e) {
      console.debug(`CO_USED_WITH edge failed ${tagA}->${tagB}: ${String(e)}`);
    }
  }

  // ---------------------------------------------------------------------------
  // M3 helper – raw Cypher query used by kuzu_query tool
  // ---------------------------------------------------------------------------

  async runQuery(cypher: string, params: Record<string, unknown> = {}): Promise<Record<string, unknown>[]> {
    if (!this._available) return [];
    try {
      const result = await this.exec(cypher, params);
      const resultObj = Array.isArray(result) ? result[0] : result;
      if (!resultObj) return [];
      const colNames: string[] = resultObj.getColumnNames ? resultObj.getColumnNames() : [];
      const rows: Record<string, unknown>[] = [];
      while (resultObj.hasNext && resultObj.hasNext()) {
        const row: unknown[] = resultObj.getNext ? resultObj.getNext() : [];
        const record: Record<string, unknown> = {};
        colNames.forEach((col: string, i: number) => { record[col] = row[i]; });
        rows.push(record);
      }
      return rows;
    } catch (e: unknown) {
      console.warn(`KùzuDB query failed: ${String(e)}`);
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // M4 helper – graph context enrichment for generate_angular_template
  // ---------------------------------------------------------------------------

  async getComponentContext(tagName: string): Promise<GraphContextEntry[]> {
    if (!this._available) return [];

    const moduleRows = await this.runQuery(
      'MATCH (c:Ui5Component {tag_name: $tag})-[:BELONGS_TO]->(m:AngularModule) ' +
      'RETURN m.module_name AS module_name, \'angular_module\' AS relation',
      { tag: tagName },
    );

    const slotRows = await this.runQuery(
      'MATCH (c:Ui5Component {tag_name: $tag})-[:HAS_SLOT]->(s:ComponentSlot) ' +
      'RETURN s.slot_name AS slot_name, \'slot\' AS relation LIMIT 10',
      { tag: tagName },
    );

    const coUsedRows = await this.runQuery(
      'MATCH (a:Ui5Component {tag_name: $tag})-[:CO_USED_WITH]->(b:Ui5Component) ' +
      'RETURN b.tag_name AS co_component, b.angular_module AS co_module, ' +
      '\'co_used_with\' AS relation LIMIT 10',
      { tag: tagName },
    );

    return [
      ...(moduleRows as GraphContextEntry[]),
      ...(slotRows as GraphContextEntry[]),
      ...(coUsedRows as GraphContextEntry[]),
    ];
  }

  async getTemplateContext(tagNames: string[]): Promise<Record<string, GraphContextEntry[]>> {
    const result: Record<string, GraphContextEntry[]> = {};
    for (const tag of tagNames) {
      result[tag] = await this.getComponentContext(tag);
    }
    return result;
  }
}
