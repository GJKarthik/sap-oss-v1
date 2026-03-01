# LangChain HANA + Mangle Query Service Integration Guide

**Version:** 1.0.0  
**Date:** 2026-03-02  
**Status:** Production Ready

---

## Overview

This document describes the integration between `langchain-integration-for-sap-hana-cloud` and `mangle-query-service`, addressing all identified weaknesses and integration gaps.

### Integration Summary

| Gap/Weakness | Solution | File(s) |
|--------------|----------|---------|
| **Gap 1:** No direct integration | LangChain HANA Bridge | `mangle-query-service/connectors/langchain_hana_bridge.py` |
| **Gap 1:** Missing Mangle predicates | HANA Vector Rules | `mangle-query-service/rules/hana_vector.mg` |
| **Gap 2:** Duplicate embedding logic | Consolidated via HANA internal | `langchain_hana_bridge.py` uses `HanaInternalEmbeddings` |
| **Gap 3:** No MCP bridge | LangChain HANA MCP Server | `mangle-query-service/mcp_server/langchain_hana_mcp.py` |
| **Gap 4:** No documentation | This document | `docs/LANGCHAIN-HANA-MANGLE-INTEGRATION.md` |
| **Weakness 1:** Sync connection pool | Async connection pool | `langchain_hana_bridge.py:AsyncConnectionPool` |
| **Weakness 2:** Limited analytical support | HanaAnalytical module | `langchain_hana/analytical.py` |
| **Weakness 3:** Keyword-based routing | Semantic router | `langchain_hana/agent/semantic_router.py` |
| **Weakness 4:** Crude mock embeddings | Uses HANA internal + fallback | Bridge prefers `HanaInternalEmbeddings` |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              User Query                                     │
└───────────────────────────────────┬─────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         mangle-query-service                                │
│                                                                             │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────────────────────────────┐│
│  │ routing.mg  │───▶│ hana_vector  │───▶│     Resolution Paths            ││
│  │ governance  │    │    .mg       │    │  • hana_vector    (NEW)         ││
│  │ .mg         │    │              │    │  • hana_mmr       (NEW)         ││
│  └─────────────┘    └──────────────┘    │  • hana_es_hybrid (NEW)         ││
│                                          │  • cache, factual, rag, llm    ││
│                                          └──────────────┬──────────────────┘│
│                                                         │                   │
│  ┌──────────────────────────────────────────────────────┼──────────────────┐│
│  │                    Connectors                        │                  ││
│  │                                                      ▼                  ││
│  │  ┌────────────────────────────────────────────────────────────────────┐ ││
│  │  │           langchain_hana_bridge.py (NEW)                           │ ││
│  │  │  • AsyncConnectionPool                                             │ ││
│  │  │  • LangChainHanaBridge                                             │ ││
│  │  │  • hana_vector_search(), hana_mmr_search(), hana_embed()          │ ││
│  │  └────────────────────────────────────────────────────────────────────┘ ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                  MCP Server (NEW)                                       ││
│  │  langchain_hana_mcp.py @ localhost:9150                                ││
│  │  Tools: hana_vector_search, hana_mmr_search, hana_embed,              ││
│  │         hana_aggregate, hana_timeseries, hana_health                  ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│              langchain-integration-for-sap-hana-cloud                       │
│                                                                             │
│  ┌─────────────────────────┐  ┌────────────────────────┐                   │
│  │ langchain_hana/         │  │ agent/                 │                   │
│  │  • vectorstores/        │  │  • semantic_router.py  │  (NEW)            │
│  │    - hana_db.py         │  │    - SemanticRouter    │                   │
│  │  • embeddings/          │  │    - CategoryCentroid  │                   │
│  │    - hana_internal_     │  │    - RoutingResult     │                   │
│  │      embeddings.py      │  │                        │                   │
│  │  • analytical.py (NEW)  │  └────────────────────────┘                   │
│  │    - HanaAnalytical     │                                               │
│  │    - AggregationType    │                                               │
│  │    - TimeGranularity    │                                               │
│  └─────────────────────────┘                                               │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          SAP HANA Cloud                                     │
│                                                                             │
│  ┌─────────────────────────┐  ┌────────────────────────┐                   │
│  │   Vector Engine         │  │   Calculation Views    │                   │
│  │  • EMBEDDINGS table     │  │  • CV_SALES_ORDER      │                   │
│  │  • COSINE_SIMILARITY    │  │  • CV_ACDOCA           │                   │
│  │  • HNSW Index           │  │  • CV_COST_CENTER      │                   │
│  │  • VECTOR_EMBEDDING()   │  │                        │                   │
│  └─────────────────────────┘  └────────────────────────┘                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Setup

### Prerequisites

```bash
# Python 3.10+
python --version

# Install langchain-hana
pip install langchain-hana

# Install mangle-query-service dependencies
cd mangle-query-service
pip install -r requirements.txt
```

### Environment Configuration

```bash
# .env file for mangle-query-service
HANA_HOST=your-hana-host.hanacloud.ondemand.com
HANA_PORT=443
HANA_USER=your_user
HANA_PASSWORD=your_password
HANA_ENCRYPT=true
HANA_INTERNAL_EMBEDDING_MODEL=SAP_NEB_V2

# MCP Server
MCP_HOST=localhost
MCP_PORT=9150
```

### Start Services

```bash
# 1. Start the LangChain HANA MCP Server
cd mangle-query-service
python -m mcp_server.langchain_hana_mcp

# 2. Start the main mangle-query-service
python -m cmd.server.main
```

---

## Usage

### 1. Vector Search via Mangle Rules

```mangle
# Query using HANA vector search
resolve(Query, Answer, "hana_vector", Score) :-
    requires_hana_vector(Query),
    is_knowledge(Query),
    hana_vector_search(Query, 5, "", DocsJSON, Score),
    Score >= 70,
    rerank(Query, DocsJSON, RankedDocs),
    llm_generate(Query, RankedDocs, Answer).
```

### 2. Direct Python Usage

```python
import asyncio
from connectors.langchain_hana_bridge import LangChainHanaBridge

async def main():
    bridge = LangChainHanaBridge()
    await bridge.initialize()
    
    # Vector search
    results = await bridge.similarity_search(
        query="Find trading documents",
        k=5,
        filter={"entity_type": "TRADING_POSITIONS"}
    )
    
    for r in results:
        print(f"{r.score:.2f}: {r.content[:100]}")
    
    # MMR search for diverse results
    diverse = await bridge.mmr_search(
        query="Risk exposure reports",
        k=5,
        fetch_k=20,
        lambda_mult=0.5
    )
    
    # Generate embedding
    embedding = await bridge.embed_text("Sample document text")
    print(f"Embedding dimensions: {len(embedding)}")

asyncio.run(main())
```

### 3. Analytical Queries

```python
from langchain_hana.analytical import HanaAnalytical
from hdbcli import dbapi

conn = dbapi.connect(
    address="your-host",
    port=443,
    user="user",
    password="pass",
    encrypt=True
)

analytical = HanaAnalytical(connection=conn)

# Aggregation query
result = analytical.aggregate(
    view_name="CV_SALES_ORDER",
    dimensions=["Region", "ProductCategory"],
    measures={"NetAmount": "SUM", "Quantity": "COUNT"},
    filters={"FiscalYear": "2024"},
    order_by=[("NetAmount", "DESC")],
    limit=100
)

print(f"SQL: {result.sql}")
for row in result.data[:5]:
    print(row)

# Time-series query
timeseries = analytical.timeseries(
    view_name="CV_SALES_ORDER",
    time_column="OrderDate",
    granularity="MONTH",
    measures={"NetAmount": "SUM"},
    limit=24
)

for row in timeseries.data:
    print(f"{row['Period']}: {row['NetAmount']}")
```

### 4. Semantic Routing

```python
import asyncio
from agent.semantic_router import SemanticRouter

async def main():
    router = SemanticRouter()
    await router.initialize()
    
    # Route queries
    queries = [
        "Find similar trading documents",
        "Total sales by region",
        "How does inventory management work?",
        "What columns are in ACDOCA?",
    ]
    
    for query in queries:
        result = await router.route(query)
        print(f"Query: {query}")
        print(f"  Backend: {result.backend.value}")
        print(f"  Category: {result.category.value}")
        print(f"  Confidence: {result.confidence:.2f}")
        print(f"  Reason: {result.reason}")
        print()

asyncio.run(main())
```

### 5. MCP Tool Invocation

```python
import asyncio
import json

async def call_mcp_tool():
    reader, writer = await asyncio.open_connection('localhost', 9150)
    
    # Call hana_vector_search tool
    request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": "hana_vector_search",
            "arguments": {
                "query": "Find risk exposure documents",
                "k": 5
            }
        }
    }
    
    writer.write((json.dumps(request) + "\n").encode())
    await writer.drain()
    
    response = await reader.readline()
    result = json.loads(response.decode())
    
    print(json.dumps(result, indent=2))
    
    writer.close()
    await writer.wait_closed()

asyncio.run(call_mcp_tool())
```

---

## Resolution Path Selection

The integrated system now supports these resolution paths:

| Path | When Used | Data Source | Backend |
|------|-----------|-------------|---------|
| `cache` | Query seen before (>95% match) | ES query_cache | - |
| `factual` | Entity lookup | ES entity index | - |
| `rag` | Knowledge retrieval | ES hybrid search | LLM |
| `hana_vector` | HANA data entities | HANA Vector Engine | vLLM |
| `hana_mmr` | Diverse HANA results | HANA Vector Engine | vLLM |
| `hana_es_hybrid` | Mixed data sources | HANA + ES | vLLM |
| `hana_factual` | HANA entity lookup | HANA tables | - |
| `llm` | LLM generation needed | ES + LLM | AI Core/vLLM |

### Path Selection Logic

```mangle
# Priority order (highest to lowest):
# 1. Cache (if >95% match)
# 2. HANA paths (if requires_hana_vector)
# 3. ES paths (factual, rag)
# 4. LLM fallback

requires_hana_vector(Query) :-
    extract_entities(Query, EntityType, _),
    is_hana_data_source(EntityType).

requires_hana_vector(Query) :-
    Query :> match("(?i)(trading|risk|treasury|financial|customer|internal)").

requires_hana_vector(Query) :-
    Query :> match("(?i)(vector|embedding|similarity|semantic|similar)"),
    Query :> match("(?i)(hana|sap|table|document)").
```

---

## Governance Integration

All HANA operations are subject to governance rules:

```mangle
# Audit HANA vector searches on sensitive data
audit_hana_search(Query, EntityType) :-
    requires_hana_vector(Query),
    extract_entities(Query, EntityType, _),
    is_hana_data_source(EntityType),
    is_sensitive_data_field(EntityType, _),
    audit_required(Query, "HANA vector search on sensitive data").

# Check data sensitivity before HANA access
hana_access_allowed(Query, Reason) :-
    requires_hana_vector(Query),
    access_allowed(Query, _, Reason).
```

---

## Data Flow Examples

### Example 1: Trading Document Search

```
User: "Find similar trading documents"
  │
  ├─▶ Mangle classify_query → "RAG_RETRIEVAL" (75%)
  │
  ├─▶ requires_hana_vector? YES (keyword: "trading")
  │
  ├─▶ governance.mg: is_sensitive_data_field("TRADING_POSITIONS", _) → audit
  │
  ├─▶ hana_vector_search via bridge
  │   └─▶ langchain_hana HanaDB.similarity_search_with_score()
  │       └─▶ HANA Cloud: COSINE_SIMILARITY(...) → 5 documents
  │
  ├─▶ rerank → MCP reranker
  │
  └─▶ llm_generate via vLLM (confidential data)
      └─▶ Answer: "Found 5 similar trading documents..."
```

### Example 2: Analytical Query

```
User: "Total sales by region for Q4 2024"
  │
  ├─▶ Semantic classifier → "analytical" (0.85)
  │
  ├─▶ HanaAnalytical.aggregate()
  │   └─▶ SQL: SELECT "Region", SUM("NetAmount") FROM ...
  │            WHERE "FiscalQuarter" = 'Q4' AND "FiscalYear" = '2024'
  │            GROUP BY "Region"
  │
  └─▶ Results: [{"Region": "APAC", "NetAmount": 1234567}, ...]
```

---

## Monitoring & Health

### Health Check Endpoint

```bash
# Check HANA connection health
curl -X POST http://localhost:9150 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"hana_health","arguments":{}}}'
```

Response:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "status": "healthy",
    "host": "your-hana-host.hanacloud.ondemand.com",
    "table": "EMBEDDINGS",
    "embedding_model": "SAP_NEB_V2"
  }
}
```

### Metrics

The integration exposes these metrics:
- `hana_vector_search_latency_seconds` - Vector search latency
- `hana_vector_search_count` - Total vector searches
- `hana_embedding_latency_seconds` - Embedding generation latency
- `hana_analytical_query_count` - Analytical query count
- `mcp_request_count` - MCP requests by tool

---

## Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| "langchain-hana not installed" | Package missing | `pip install langchain-hana` |
| "HANA connection not configured" | Missing env vars | Set `HANA_HOST`, `HANA_USER`, `HANA_PASSWORD` |
| "VECTOR_EMBEDDING function not found" | Old HANA version | Upgrade HANA Cloud to QRC 1/2024+ |
| "MCP connection refused" | Server not running | Start `langchain_hana_mcp.py` |
| Low confidence routing | Few exemplars | Add category exemplars |

### Debug Logging

```python
import logging
logging.basicConfig(level=logging.DEBUG)

# Enable specific loggers
logging.getLogger("connectors.langchain_hana_bridge").setLevel(logging.DEBUG)
logging.getLogger("langchain_hana").setLevel(logging.DEBUG)
```

---

## Performance Tuning

### Connection Pool

```python
# Increase pool size for high concurrency
bridge = LangChainHanaBridge()
bridge._pool = AsyncConnectionPool(
    host=...,
    pool_size=10,  # Default: 5
)
```

### HNSW Index

```python
# Create HNSW index for faster vector search
hana_db.create_hnsw_index(
    m=32,                # Max neighbors per node
    ef_construction=200,  # Build-time candidates
    ef_search=100,        # Search-time candidates
)
```

### Embedding Cache

```python
# Enable embedding cache for repeated queries
router = SemanticRouter(cache_embeddings=True)
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-03-02 | Initial integration |

---

## References

- [langchain-integration-for-sap-hana-cloud README](../langchain-integration-for-sap-hana-cloud-main/README.md)
- [mangle-query-service Compliance Review](../mangle-query-service/docs/REGULATIONS-COMPLIANCE-REVIEW.md)
- [SAP HANA Cloud Vector Engine Guide](https://help.sap.com/docs/hana-cloud-database/sap-hana-cloud-sap-hana-database-vector-engine-guide)