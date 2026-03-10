# KùzuDB Graph Store — MCP Server

## Overview

The MCP server embeds [KùzuDB](https://kuzudb.com/) as an in-process property graph
database. It stores UI5 Web Component relationships and is used to enrich
`generate_angular_template` responses with co-usage and slot context
(**Graph-RAG**).

KùzuDB is **optional** — the MCP server starts and works without it. Graph
features degrade gracefully when the `kuzu` npm package is absent.

---

## Schema

### Node Tables

| Table | Primary Key | Fields | Description |
|---|---|---|---|
| `Ui5Component` | `tag_name` | `angular_module`, `npm_module` | A UI5 Web Component |
| `AngularModule` | `module_name` | `package` | An Angular NgModule |
| `ComponentSlot` | `slot_id` | `tag_name`, `slot_name` | A named slot on a component |

### Relationship Tables

| Table | From → To | Fields | Description |
|---|---|---|---|
| `BELONGS_TO` | `Ui5Component → AngularModule` | — | Component belongs to a module |
| `HAS_SLOT` | `Ui5Component → ComponentSlot` | — | Component exposes a named slot |
| `CO_USED_WITH` | `Ui5Component → Ui5Component` | `weight INTEGER` | Components frequently co-appear in templates |

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `KUZU_DB_PATH` | `:memory:` | Path to KùzuDB database directory. Use `:memory:` for ephemeral (test/dev) or a filesystem path for persistence. |

---

## Enabling KùzuDB

Add `kuzu` to `mcp-server/package.json`:

```json
{
  "dependencies": {
    "kuzu": ">=0.7.0"
  }
}
```

Then run `yarn install` from the workspace root.

---

## MCP Tools

### `kuzu_index`

Indexes component definitions into the graph. Accepts a JSON array of component
definitions:

```json
[
  {
    "tag_name": "ui5-button",
    "angular_module": "Ui5ButtonModule",
    "npm_module": "@ui5/webcomponents/dist/Button",
    "slots": ["default", "icon"],
    "co_used_with": ["ui5-dialog", "ui5-toolbar"]
  }
]
```

### `kuzu_query`

Executes a **read-only** Cypher query against the graph. Write statements
(`CREATE`, `MERGE`, `DELETE`, `SET`, `REMOVE`, `DROP`) are blocked.

Example:

```cypher
MATCH (a:Ui5Component {tag_name: 'ui5-button'})-[:CO_USED_WITH]->(b)
RETURN b.tag_name AS co_component LIMIT 5
```

---

## Database File Persistence

For production deployments set `KUZU_DB_PATH` to a persistent volume path:

```bash
export KUZU_DB_PATH=/var/data/ui5-mcp-graph
```

The database directory is created automatically on first run.

---

## `.npmignore`

The `kuzu/` directory (this documentation folder) is excluded from any published
npm package. The KùzuDB binary itself lives in `node_modules/kuzu/` and is
never committed to the repository.
