# KùzuDB Integration Roadmap

## Current Status

The `kuzu/` directory contains a vendored snapshot of
[KùzuDB](https://kuzudb.com/) (MIT licence, © 2022-2025 Kùzu Inc.).
It is **not imported or used** by any Python component in this repository
and is **not included** in the container image built by `Dockerfile.sap`.

## Planned Integration: Graph-Based RAG Indexing

KùzuDB is earmarked as the **local graph store** for the HANA DTA mesh,
serving as an embedded alternative to a networked Neo4j instance in the
`deductive-db` mesh role.

### Target architecture

```
HANA Cloud                Elasticsearch
   │                           │
   │  hana_index_to_es         │  es_search / ai_semantic_search
   └──────────────────────────►│
                               │
              ┌────────────────┘
              │  Graph extraction
              ▼
         KùzuDB (embedded)
              │
              │  Cypher / MATCH queries
              ▼
         Graph-enhanced context
              │
              └──► SAP AI Core (RAG prompt augmentation)
```

### Milestones

| Milestone | Description | Priority |
|-----------|-------------|----------|
| M1 | Define graph schema for OData entity relationships | High |
| M2 | Add `kuzu_index` MCP tool: extract entity graph from ES search results → KùzuDB | High |
| M3 | Add `kuzu_query` MCP tool: Cypher query with result serialisation | Medium |
| M4 | Wire graph context into `ai_semantic_search` RAG prompt | Medium |
| M5 | Register KùzuDB tools in `mangle/a2a/mcp.mg` and `mangle/domain/agents.mg` | Medium |
| M6 | Include `kuzu/` Python wheel in `Dockerfile.sap` build stage | Low |

### Licensing note

KùzuDB is MIT-licenced, distinct from the Apache-2.0 licence applied to the
SAP-added Python components in this repository and from the Elastic
Licence 2.0 / SSPL / AGPL applied to upstream Elasticsearch code.
Any distribution that bundles the compiled KùzuDB shared library must
preserve the MIT copyright notice in `kuzu/LICENSE`.

## Decision to Retain

The vendored directory is retained (rather than removed) because:

1. The planned graph-RAG integration has been approved on the roadmap.
2. Vendoring avoids a runtime `pip install` of a large native extension in
   restricted BTP environments.
3. The MIT licence is compatible with both the Apache-2.0 SAP components and
   the distribution requirements of the project.

If the graph-RAG milestone is de-scoped, `kuzu/` should be removed from the
repository and this document updated accordingly to close the compliance
surface area.
