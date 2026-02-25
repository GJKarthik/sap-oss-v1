# Integration Review: ai-sdk-js ↔ elasticsearch

**Review Date:** 2026-02-25  
**Reviewer:** Architecture Review  
**Status:** Complete ✅

---

## Executive Summary

| Metric | Rating |
|--------|--------|
| **Integration Potential** | ⭐⭐⭐⭐☆ (4/5) |
| **Current Integration** | ❌ None |
| **Quality Score** | 7/10 (as an integration pair) |
| **Recommended Priority** | High |
| **Effort to Integrate** | Medium |

**Verdict:** Excellent integration potential. Elasticsearch's vector search and RAG capabilities align perfectly with SAP AI SDK's document grounding and foundation model needs. This integration would enable enterprise-grade semantic search and knowledge retrieval for SAP AI applications.

---

## 1. Project Profiles

### 1.1 ai-sdk-js (SAP Cloud SDK for AI)

| Attribute | Value |
|-----------|-------|
| **Language** | TypeScript/JavaScript |
| **Primary Purpose** | SDK for SAP AI Core, Generative AI Hub, Orchestration |
| **Core Packages** | `foundation-models`, `orchestration`, `document-grounding`, `langchain` |
| **Key Features** | Chat completion, templating, grounding, data masking, content filtering |
| **Target Platform** | Node.js, SAP BTP |

**Key Packages:**
- `@sap-ai-sdk/foundation-models` - LLM integration (OpenAI, Azure, etc.)
- `@sap-ai-sdk/document-grounding` - Vector API, Retrieval API, Pipeline API
- `@sap-ai-sdk/orchestration` - Workflow orchestration for AI pipelines
- `@sap-ai-sdk/langchain` - LangChain model client adapters

### 1.2 Elasticsearch

| Attribute | Value |
|-----------|-------|
| **Language** | Java |
| **Primary Purpose** | Distributed search engine, vector database, analytics |
| **Key Features** | Full-text search, vector search, RAG, real-time indexing |
| **Query Language** | Query DSL (JSON), SQL, EQL |
| **Deployment** | Self-hosted, Elastic Cloud |

**Key Capabilities:**
- **Vector Search** - Dense/sparse vector similarity with HNSW, IVF
- **Hybrid Search** - Combine BM25 text search with vector similarity
- **RAG Support** - Built-in retrieval for LLM grounding
- **Real-time Indexing** - Near real-time document availability
- **Scalability** - Distributed architecture for enterprise workloads

---

## 2. Technical Compatibility Analysis

### 2.1 Language & Runtime Compatibility

| Aspect | ai-sdk-js | Elasticsearch |
|--------|-----------|---------------|
| Runtime | Node.js | JVM (Server) |
| Client Access | Native | REST API / JS Client |
| Type System | TypeScript | JSON Schema |
| Package Manager | npm/pnpm | Maven/Gradle |

**Gap Assessment:** 🟢 **Minimal** - Elasticsearch provides official JavaScript client (`@elastic/elasticsearch`)

### 2.2 Architectural Alignment

| Concept | ai-sdk-js | Elasticsearch |
|---------|-----------|---------------|
| Document Storage | Document Grounding API | Index/Documents |
| Vector Embeddings | Via foundation models | Dense vector fields |
| Retrieval | Retrieval API | `_search` with kNN |
| Chunking | Pipeline API | Ingest pipelines |
| Semantic Search | Orchestration | Vector + BM25 hybrid |

**Gap Assessment:** 🟢 **Strong** - Concepts map directly

### 2.3 Integration Points

```
┌─────────────────────────────────────────────────────────────┐
│                     SAP AI Application                       │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                @sap-ai-sdk/orchestration                     │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │  Template   │  │   Ground    │  │   Content Filter    │  │
│  │  Module     │  │   Module    │◄─┼──────────────────────│  │
│  └─────────────┘  └──────┬──────┘  └─────────────────────┘  │
└──────────────────────────┼──────────────────────────────────┘
                           │ retrieval request
                           ▼
┌─────────────────────────────────────────────────────────────┐
│           @sap-ai-sdk/document-grounding                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │ Pipeline API │  │  Vector API  │  │  Retrieval API   │   │
│  └──────────────┘  └──────────────┘  └────────┬─────────┘   │
└───────────────────────────────────────────────┼─────────────┘
                                                │
              ┌─────────────────────────────────┘
              │ elasticsearch-connector (NEW)
              ▼
┌─────────────────────────────────────────────────────────────┐
│                      Elasticsearch                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │   Indices    │  │  Vector DB   │  │  Ingest Pipeline │   │
│  │  (Documents) │  │  (kNN/HNSW)  │  │  (Chunking/Embed)│   │
│  └──────────────┘  └──────────────┘  └──────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Integration Opportunities

### 3.1 Opportunity: Elasticsearch as Document Grounding Backend

**Concept:** Use Elasticsearch as the vector database for `@sap-ai-sdk/document-grounding`

**Implementation Approach:**
```typescript
// packages/document-grounding/src/elasticsearch-connector.ts
import { Client } from '@elastic/elasticsearch';
import { VectorStore, DocumentChunk, RetrievalResult } from './types';

export class ElasticsearchVectorStore implements VectorStore {
  private client: Client;
  private indexName: string;
  
  constructor(config: ElasticsearchConfig) {
    this.client = new Client({
      node: config.endpoint,
      auth: { apiKey: config.apiKey }
    });
    this.indexName = config.indexName;
  }
  
  async upsertDocuments(chunks: DocumentChunk[]): Promise<void> {
    const operations = chunks.flatMap(chunk => [
      { index: { _index: this.indexName, _id: chunk.id } },
      {
        content: chunk.content,
        embedding: chunk.embedding,  // dense_vector field
        metadata: chunk.metadata,
      }
    ]);
    
    await this.client.bulk({ operations });
  }
  
  async retrieve(
    queryEmbedding: number[],
    options: RetrievalOptions
  ): Promise<RetrievalResult[]> {
    const response = await this.client.search({
      index: this.indexName,
      knn: {
        field: 'embedding',
        query_vector: queryEmbedding,
        k: options.topK || 10,
        num_candidates: options.numCandidates || 100,
      },
      // Optional: Hybrid search with BM25
      query: options.textQuery ? {
        match: { content: options.textQuery }
      } : undefined,
    });
    
    return response.hits.hits.map(hit => ({
      id: hit._id,
      content: hit._source.content,
      score: hit._score,
      metadata: hit._source.metadata,
    }));
  }
}
```

**Value Assessment:**
- ✅ Enterprise-grade vector search with proven scalability
- ✅ Hybrid search (vector + BM25) for better retrieval
- ✅ Real-time indexing for dynamic knowledge bases
- ✅ Mature ecosystem with monitoring, security, multi-tenancy
- ⚠️ Requires Elasticsearch deployment (cloud or self-hosted)

**Effort:** Medium (2-3 weeks)  
**Value:** High

### 3.2 Opportunity: RAG Pipeline Integration

**Concept:** Build end-to-end RAG pipeline using ai-sdk-js orchestration with Elasticsearch retrieval

**Implementation Approach:**
```typescript
// Example: RAG with Elasticsearch retrieval
import { OrchestrationClient } from '@sap-ai-sdk/orchestration';
import { ElasticsearchVectorStore } from './elasticsearch-connector';
import { AzureOpenAiEmbeddingClient } from '@sap-ai-sdk/foundation-models';

class ElasticsearchRAGModule {
  private vectorStore: ElasticsearchVectorStore;
  private embeddingClient: AzureOpenAiEmbeddingClient;
  
  async ground(query: string): Promise<GroundingContext> {
    // Generate query embedding
    const embedding = await this.embeddingClient.embed(query);
    
    // Retrieve from Elasticsearch with hybrid search
    const results = await this.vectorStore.retrieve(embedding.vector, {
      topK: 5,
      textQuery: query,  // Enable hybrid search
    });
    
    return {
      context: results.map(r => r.content).join('\n\n'),
      sources: results.map(r => r.metadata.source),
    };
  }
}

// Usage in orchestration
const orchestrationClient = new OrchestrationClient();
const ragModule = new ElasticsearchRAGModule(config);

const response = await orchestrationClient.chat({
  messages: [{ role: 'user', content: 'What is our return policy?' }],
  grounding: {
    module: ragModule,
    strategy: 'semantic',
  },
});
```

**Value Assessment:**
- ✅ Leverages Elasticsearch's hybrid search for better relevance
- ✅ Scales to millions of documents
- ✅ Supports multiple retrieval strategies
- ⚠️ Additional latency for retrieval step

**Effort:** Medium (2-3 weeks)  
**Value:** Very High

### 3.3 Opportunity: Elasticsearch Ingest Pipeline for Document Processing

**Concept:** Use Elasticsearch ingest pipelines for document chunking and embedding

```typescript
// Create embedding ingest pipeline
await client.ingest.putPipeline({
  id: 'sap-ai-embedding-pipeline',
  processors: [
    {
      inference: {
        model_id: 'sap-ai-embedding-model',
        input_output: [
          { input_field: 'content', output_field: 'embedding' }
        ]
      }
    }
  ]
});

// Index document - embedding generated automatically
await client.index({
  index: 'knowledge-base',
  pipeline: 'sap-ai-embedding-pipeline',
  document: {
    content: 'Your document text here',
    metadata: { source: 'policy-manual.pdf' }
  }
});
```

**Value Assessment:**
- ✅ Offloads embedding generation to Elasticsearch
- ✅ Automatic re-embedding on update
- ⚠️ Requires ML model deployment in Elasticsearch

**Effort:** Low (1 week)  
**Value:** Medium

---

## 4. Quality Assessment

### 4.1 Individual Project Scores

| Criterion | ai-sdk-js | Elasticsearch |
|-----------|-----------|---------------|
| Code Quality | 8/10 | 9/10 |
| Documentation | 8/10 | 9/10 |
| Test Coverage | 8/10 | 9/10 |
| Type Safety | 9/10 | N/A (Java) |
| API Design | 8/10 | 9/10 |
| Scalability | 7/10 | 10/10 |
| **Average** | **8.0/10** | **9.2/10** |

### 4.2 Integration Quality Score

| Criterion | Score | Notes |
|-----------|-------|-------|
| Architectural Fit | 8/10 | Perfect for document grounding use case |
| Semantic Overlap | 9/10 | Vector search, retrieval, RAG align perfectly |
| Technical Readiness | 7/10 | Elasticsearch JS client is mature |
| Value Proposition | 9/10 | Enterprise search + AI = high value |
| Implementation Effort | 7/10 | Medium effort, clear path |
| **Integration Score** | **7/10** | Recommended |

---

## 5. Recommendations

### 5.1 ✅ Pursue Integration

**Priority: High**

The integration between ai-sdk-js and Elasticsearch is highly recommended:

1. **Create `@sap-ai-sdk/elasticsearch` package**
   - Elasticsearch connector implementing VectorStore interface
   - Support for hybrid search (vector + BM25)
   - Integration with document grounding APIs

2. **Add Elasticsearch retriever to orchestration**
   - Native Elasticsearch grounding module
   - Configuration-driven setup

3. **Documentation and samples**
   - RAG pipeline examples
   - Deployment guides for Elastic Cloud / self-hosted

### 5.2 Implementation Roadmap

| Week | Deliverable |
|------|-------------|
| 1 | ElasticsearchVectorStore class with kNN search |
| 2 | Hybrid search support, ingest pipeline integration |
| 3 | Integration with orchestration grounding module |
| 4 | Documentation, samples, testing |

### 5.3 Architecture Decision

```
@sap-ai-sdk/document-grounding
    │
    ├── vector-stores/
    │   ├── sap-hana-cloud.ts (existing)
    │   ├── elasticsearch.ts (NEW)
    │   └── interface.ts
    │
    └── retrieval/
        ├── semantic-retriever.ts
        └── hybrid-retriever.ts (NEW - ES specific)
```

---

## 6. Appendix: Code Evidence

### 6.1 Elasticsearch Vector Search API

```json
POST /knowledge-base/_search
{
  "knn": {
    "field": "embedding",
    "query_vector": [0.1, 0.2, ...],
    "k": 10,
    "num_candidates": 100
  },
  "_source": ["content", "metadata"]
}
```

### 6.2 Elasticsearch Hybrid Search

```json
POST /knowledge-base/_search
{
  "query": {
    "bool": {
      "should": [
        {
          "match": {
            "content": {
              "query": "return policy",
              "boost": 0.3
            }
          }
        }
      ]
    }
  },
  "knn": {
    "field": "embedding",
    "query_vector": [0.1, 0.2, ...],
    "k": 10,
    "num_candidates": 100,
    "boost": 0.7
  }
}
```

---

## Review Sign-off

| Role | Name | Date | Approval |
|------|------|------|----------|
| Reviewer | Architecture Team | 2026-02-25 | ✅ |
| Technical Lead | - | - | ⬜ Pending |
| Product Owner | - | - | ⬜ Pending |