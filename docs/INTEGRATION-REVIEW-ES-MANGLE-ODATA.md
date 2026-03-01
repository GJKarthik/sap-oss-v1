# Integration Review: Elasticsearch, Mangle Query Service, and OData Vocabularies

**Review Date:** March 1, 2026  
**Reviewer:** SAP Open Source AI Platform Team

---

## Executive Summary

This document reviews the integration architecture between three key repositories:

1. **elasticsearch-main**: Core search and analytics engine with SAP AI extensions
2. **mangle-query-service**: Go-based Mangle reasoning engine with ES predicates
3. **odata-vocabularies-main**: SAP OData vocabulary definitions and ES connector

These three repositories form a **semantic search and reasoning pipeline** that enables AI agents to query enterprise data with OData semantics, vector search capabilities, and declarative reasoning.

### Integration Rating: ⭐⭐⭐⭐⭐ (4.5/5.0)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SAP AI Agent Mesh                                  │
└───────────────────────────────┬─────────────────────────────────────────────┘
                                │
                    ┌───────────▼───────────┐
                    │  Mangle Query Service  │
                    │       (Go/gRPC)       │
                    │                       │
                    │  • Mangle Predicates  │
                    │  • ES Hybrid Search   │
                    │  • MCP Classification │
                    └───────────┬───────────┘
                                │
         ┌──────────────────────┼──────────────────────┐
         │                      │                      │
         ▼                      ▼                      ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐
│  Elasticsearch  │  │  OData Vocabs   │  │    LLM Backends     │
│    (Search)     │  │  (Semantics)    │  │  (vLLM / AI Core)   │
│                 │  │                 │  │                     │
│ • BM25 + kNN    │  │ • Term defs     │  │ • Embeddings        │
│ • RRF Fusion    │  │ • Annotations   │  │ • Reranking         │
│ • Vector Index  │  │ • GDPR/Personal │  │ • Classification    │
└─────────────────┘  └─────────────────┘  └─────────────────────┘
```

---

## Integration Points

### 1. Elasticsearch ↔ Mangle Query Service

**Connection Type:** Go ES Client (elastic/go-elasticsearch v8)

**Integration Files:**
- `mangle-query-service/internal/es/client.go` - ES client wrapper
- `mangle-query-service/internal/es/hybrid.go` - BM25+kNN hybrid search
- `mangle-query-service/internal/predicates/es_hybrid.go` - Mangle predicate

**Key Integration Pattern:**
```go
// ESHybridPredicate implements es_hybrid_search/3: (Query, DocsJSON, TopScore)
type ESHybridPredicate struct {
    ES         *elasticsearch.Client
    Index      string
    KNNWeight  float64  // 0.7 default
    BM25Weight float64  // 0.3 default
    TopK       int      // 5 default
    EmbeddingFn func(ctx context.Context, text string) ([]float32, error)
}
```

**Data Flow:**
1. Mangle rule queries `es_hybrid_search(Query, Docs, Score)`
2. Predicate calls ES with BM25 + kNN sub_searches
3. Results ranked with RRF (Reciprocal Rank Fusion)
4. JSON results returned to Mangle for reasoning

**Rating: 4.8/5.0** - Excellent hybrid search implementation with configurable weights

---

### 2. Elasticsearch ↔ OData Vocabularies

**Connection Type:** Python Elasticsearch client

**Integration Files:**
- `odata-vocabularies-main/connectors/elasticsearch.py` - ES client
- `mangle-query-service/es_mappings/odata_entity_index.json` - Index mapping

**Key Integration Pattern:**
```python
class ElasticsearchClient:
    """Elasticsearch client for OData vocabulary operations."""
    
    def create_vocabulary_index(self, index_name: str = None) -> Dict:
        """Create index with vocabulary-optimized mappings."""
        
    def create_entity_index(self, index_name: str = None) -> Dict:
        """Create index for OData entities."""
        
    def create_audit_index(self, index_name: str = None) -> Dict:
        """Create index for audit logs."""
        
    def semantic_search(self, embedding: List[float], ...) -> Dict:
        """Semantic search using vector similarity."""
```

**OData Entity Index Mapping (mangle-query-service):**
```json
{
  "mappings": {
    "properties": {
      "entity_type": {"type": "keyword"},
      "odata_metadata": { /* namespace, entity_set, key_properties */ },
      "common_annotations": { /* label, description, semantic_object */ },
      "analytics_annotations": { /* dimensions, measures */ },
      "personal_data": { /* GDPR fields */ },
      "hana_metadata": { /* schema, calculation_view */ },
      "display_text_embedding": {
        "type": "dense_vector",
        "dims": 1536,
        "similarity": "cosine"
      }
    }
  }
}
```

**Rating: 4.6/5.0** - Comprehensive OData-aware mapping with vector search support

---

### 3. Mangle Query Service ↔ OData Vocabularies

**Connection Type:** MCP (Model Context Protocol) + Shared ES Index

**Integration Files:**
- `mangle-query-service/internal/predicates/mcp_entities.go` - Entity resolution
- `mangle-query-service/es_mappings/odata_entity_index.json` - Shared schema
- `odata-vocabularies-main/mangle/domain/vocabularies.mg` - Vocabulary facts

**Key Integration Pattern:**
```
┌───────────────────┐         ┌───────────────────┐
│  Mangle Service   │   MCP   │  OData Vocab Svc  │
│                   │◄───────►│                   │
│  mcp_classify/2   │         │  vocabulary_terms │
│  mcp_entities/3   │         │  entity_types     │
│  mcp_rerank/4     │         │  annotations      │
└───────────────────┘         └───────────────────┘
          │                           │
          └───────────┬───────────────┘
                      ▼
            ┌─────────────────┐
            │  Elasticsearch  │
            │                 │
            │  odata_entity   │
            │  index          │
            └─────────────────┘
```

**Shared Index Schema:**
- Both services read/write to `odata_entity` index
- Vocabulary annotations embedded in entity documents
- HANA metadata for source system tracking
- Personal data tracking for GDPR compliance

**Rating: 4.3/5.0** - Good shared schema design, needs better synchronization

---

## Integration Quality Assessment

### Strengths

| Area | Score | Details |
|------|-------|---------|
| **Schema Alignment** | 4.7 | OData entity index maps all vocabulary terms |
| **Hybrid Search** | 4.8 | BM25 + kNN with RRF fusion |
| **GDPR Support** | 4.5 | Personal data tracking in ES schema |
| **Vector Search** | 4.6 | 1536-dim embeddings (text-embedding-3-small) |
| **Analytics Support** | 4.4 | Dimensions/measures in OData annotations |
| **Audit Logging** | 4.5 | Dedicated audit index with retention |

### Weaknesses

| Area | Score | Issue | Recommendation |
|------|-------|-------|----------------|
| **Sync Mechanism** | 3.5 | CDC listener is POC-level | Implement robust CDC with Debezium |
| **Cache Invalidation** | 3.2 | Basic implementation | Add Redis-based cache layer |
| **Error Propagation** | 3.8 | Silent failures in predicates | Add structured error handling |
| **Schema Versioning** | 3.6 | Version in _meta but no migration | Add ES index migration scripts |
| **Integration Tests** | 3.5 | Limited cross-service tests | Add end-to-end integration suite |

---

## Data Flow Analysis

### Query Path: Natural Language → Elasticsearch

```
User Query: "Show me customer orders with high value"
    │
    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 1. elasticsearch-main/agent/elasticsearch_agent.py                   │
│    MangleEngine.query("route_to_vllm", "customer orders")           │
│    → Routes to vLLM (confidential index pattern)                    │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 2. mangle-query-service/internal/predicates/mcp_classify.go          │
│    mcp_classify(Query, EntityType)                                   │
│    → Calls OData vocab service to resolve entity type                │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 3. odata-vocabularies-main/connectors/elasticsearch.py               │
│    search("customer orders") on odata_vocabulary index               │
│    → Returns: EntityType="SalesOrder", Annotations=[...]            │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 4. mangle-query-service/internal/predicates/es_hybrid.go             │
│    es_hybrid_search("customer orders high value", Docs, Score)       │
│    → Executes BM25 + kNN hybrid on odata_entity index               │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 5. elasticsearch-main (ES Cluster)                                   │
│    POST /odata_entity/_search                                        │
│    { "sub_searches": [{ "query": ... }, { "knn": ... }] }           │
│    → Returns ranked documents                                        │
└─────────────────────────────────────────────────────────────────────┘
```

### Sync Path: HANA → Elasticsearch

```
┌─────────────────────────────────────────────────────────────────────┐
│ 1. SAP HANA Cloud (Source of Truth)                                  │
│    • Business entities with OData annotations                        │
│    • Personal data classifications                                   │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ CDC (Change Data Capture)
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 2. mangle-query-service/internal/sync/batch_etl.go                   │
│    • BatchETL.RunFullSync() - Full extraction                        │
│    • Transforms HANA rows to OData-annotated documents               │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 3. odata-vocabularies-main/connectors/elasticsearch.py               │
│    • ElasticsearchClient.bulk_index(documents, "odata_entity")       │
│    • Includes vocabulary annotations per entity                      │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 4. Elasticsearch Index: odata_entity                                 │
│    • entity_type: "SalesOrder"                                       │
│    • common_annotations: { label: "Sales Order", ... }               │
│    • personal_data: { is_data_subject: false, ... }                 │
│    • display_text_embedding: [0.123, -0.456, ...]                   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## API Compatibility Matrix

| Service | Protocol | Port | Auth | Status |
|---------|----------|------|------|--------|
| ES Cluster | REST/HTTP | 9200 | API Key / Basic | ✅ Production |
| ES MCP Server | JSON-RPC 2.0 | 9120 | None (internal) | ✅ Ready |
| ES OpenAI Server | HTTP/SSE | 9201 | Bearer Token | ✅ Ready |
| Mangle Service | gRPC | 50051 | mTLS | ✅ Production |
| OData Vocab MCP | JSON-RPC 2.0 | 9100 | Bearer Token | ✅ Ready |

---

## Recommendations

### High Priority

1. **Unified Index Schema**
   - Merge `odata_entity_index.json` with OData vocab ES connector
   - Single source of truth for index mapping

2. **Integration Test Suite**
   ```bash
   # Proposed structure
   tests/integration/
   ├── test_es_mangle_query.py
   ├── test_odata_entity_search.py
   ├── test_hybrid_search_rrr.py
   └── test_gdpr_audit_logging.py
   ```

3. **CDC Implementation**
   - Replace POC CDC with Debezium connector
   - Add Kafka/Event Hub for reliable event streaming

### Medium Priority

1. **Schema Migration Tooling**
   - ES index reindexing scripts
   - Zero-downtime migration support

2. **Observability**
   - Distributed tracing across all three services
   - Shared correlation IDs

3. **Configuration Alignment**
   - Shared config for ES connection strings
   - Service discovery for dynamic endpoints

### Low Priority

1. **Language Unification**
   - Consider Rust/Zig for all ES predicates
   - Or standardize on Go for non-critical Python code

---

## Conclusion

The integration between Elasticsearch, Mangle Query Service, and OData Vocabularies represents a **well-architected semantic search pipeline** for enterprise AI applications. The key strengths are:

- **Hybrid Search Excellence**: BM25 + kNN with RRF fusion
- **OData Semantics**: Full vocabulary annotation support
- **GDPR Compliance**: Personal data tracking built-in
- **Extensibility**: Mangle predicates for declarative reasoning

The primary areas for improvement are CDC reliability and integration testing. Overall, this integration provides a solid foundation for AI agents to query enterprise data with semantic understanding.

**Integration Rating: 4.5/5.0** ⭐⭐⭐⭐⭐

---

*This review was conducted as part of the SAP Open Source AI Platform initiative.*