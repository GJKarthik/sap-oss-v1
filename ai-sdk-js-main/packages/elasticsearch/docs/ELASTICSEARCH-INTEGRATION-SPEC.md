# Elasticsearch Integration Technical Specification

**Package:** `@sap-ai-sdk/elasticsearch`  
**Version:** 0.1.0  
**Date:** 2026-03-26  
**Status:** Draft  

---

## 1. Overview

This specification defines the integration between SAP AI SDK and Elasticsearch for vector storage and hybrid search capabilities. The integration enables:

1. **Vector Storage** - Store and manage document embeddings in Elasticsearch
2. **kNN Search** - Semantic search using approximate nearest neighbors
3. **Hybrid Search** - Combine vector similarity with BM25 text search
4. **RAG Integration** - Serve as a grounding module for orchestration

---

## 2. Elasticsearch API Analysis

### 2.1 Vector Search (kNN)

Elasticsearch 8.x provides native vector search through the `dense_vector` field type and kNN search API.

#### Index Mapping

```json
{
  "mappings": {
    "properties": {
      "embedding": {
        "type": "dense_vector",
        "dims": 1536,
        "index": true,
        "similarity": "cosine"
      },
      "content": {
        "type": "text",
        "analyzer": "standard"
      },
      "metadata": {
        "type": "object",
        "enabled": true
      }
    }
  }
}
```

#### Similarity Metrics

| Metric | Description | Use Case |
|--------|-------------|----------|
| `cosine` | Cosine similarity | Most text embeddings (OpenAI, etc.) |
| `dot_product` | Dot product | Normalized embeddings |
| `l2_norm` | Euclidean distance | Image embeddings |

#### kNN Query

```json
{
  "knn": {
    "field": "embedding",
    "query_vector": [0.1, 0.2, ...],
    "k": 10,
    "num_candidates": 100
  }
}
```

### 2.2 Hybrid Search

Combine kNN with traditional search using `bool` queries and `script_score`.

```json
{
  "query": {
    "bool": {
      "should": [
        {
          "match": {
            "content": "search query"
          }
        }
      ],
      "filter": [
        {
          "term": {
            "metadata.category": "technology"
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
    "boost": 0.5
  }
}
```

### 2.3 Bulk Indexing

```json
POST /_bulk
{"index": {"_index": "documents", "_id": "1"}}
{"content": "Document 1", "embedding": [0.1, ...], "metadata": {...}}
{"index": {"_index": "documents", "_id": "2"}}
{"content": "Document 2", "embedding": [0.2, ...], "metadata": {...}}
```

### 2.4 Ingest Pipelines

Elasticsearch can automatically generate embeddings via ingest pipelines:

```json
PUT _ingest/pipeline/embed-pipeline
{
  "processors": [
    {
      "inference": {
        "model_id": "sentence-transformers__all-minilm-l6-v2",
        "target_field": "embedding",
        "field_map": {
          "content": "text_field"
        }
      }
    }
  ]
}
```

---

## 3. Interface Design

### 3.1 ElasticsearchConfig

```typescript
interface ElasticsearchConfig {
  // Connection
  node: string | string[];                    // ES node URL(s)
  cloud?: { id: string };                     // Elastic Cloud ID
  auth?: {
    username?: string;
    password?: string;
    apiKey?: string;
    bearer?: string;
  };
  
  // Index settings
  indexName: string;                          // Target index name
  
  // Vector settings
  embeddingDims: number;                      // Vector dimensions (e.g., 1536)
  embeddingField?: string;                    // Field name (default: "embedding")
  similarity?: 'cosine' | 'dot_product' | 'l2_norm';  // Similarity metric
  
  // Content settings
  contentField?: string;                      // Text field (default: "content")
  metadataField?: string;                     // Metadata field (default: "metadata")
  
  // Connection options
  maxRetries?: number;                        // Max retry attempts
  requestTimeout?: number;                    // Request timeout in ms
  compression?: boolean;                      // Enable compression
  
  // Embedding provider
  embedder?: EmbeddingProvider;               // For automatic embedding
}

interface EmbeddingProvider {
  embed(texts: string[]): Promise<number[][]>;
  getDimensions(): number;
}
```

### 3.2 Document Types

```typescript
interface Document {
  id?: string;                                // Document ID (auto-generated if not provided)
  content: string;                            // Text content
  embedding?: number[];                       // Pre-computed embedding (optional)
  metadata?: Record<string, unknown>;         // Arbitrary metadata
}

interface IndexedDocument extends Document {
  id: string;                                 // Guaranteed to have ID
  embedding: number[];                        // Guaranteed to have embedding
  indexedAt: Date;                            // Index timestamp
}

interface SearchResult<T = unknown> {
  id: string;
  score: number;                              // Combined score
  content: string;
  metadata?: Record<string, T>;
  embedding?: number[];                       // Optional: include embedding
  highlights?: string[];                      // Text highlights
}
```

### 3.3 ElasticsearchVectorStore

```typescript
class ElasticsearchVectorStore {
  constructor(config: ElasticsearchConfig);
  
  // Lifecycle
  initialize(): Promise<void>;                // Create index if needed
  close(): Promise<void>;                     // Close connection
  
  // Index management
  createIndex(settings?: IndexSettings): Promise<void>;
  deleteIndex(): Promise<void>;
  indexExists(): Promise<boolean>;
  getIndexStats(): Promise<IndexStats>;
  
  // Document operations
  upsertDocuments(docs: Document[]): Promise<BulkResult>;
  upsertDocument(doc: Document): Promise<string>;
  deleteDocuments(ids: string[]): Promise<BulkResult>;
  deleteDocument(id: string): Promise<boolean>;
  getDocument(id: string): Promise<IndexedDocument | null>;
  
  // Search operations
  retrieve(query: string | number[], options?: RetrieveOptions): Promise<SearchResult[]>;
  hybridSearch(query: string, embedding: number[], options?: HybridSearchOptions): Promise<SearchResult[]>;
  
  // Raw query access
  search(query: SearchQuery): Promise<SearchResponse>;
}

interface RetrieveOptions {
  k?: number;                                 // Number of results (default: 10)
  numCandidates?: number;                     // kNN candidates (default: k * 10)
  minScore?: number;                          // Minimum score threshold
  filter?: Record<string, unknown>;           // Metadata filter
  includeEmbedding?: boolean;                 // Include embeddings in results
  includeHighlights?: boolean;                // Include text highlights
}

interface HybridSearchOptions extends RetrieveOptions {
  vectorWeight?: number;                      // Vector score weight (0-1, default: 0.5)
  textWeight?: number;                        // Text score weight (0-1, default: 0.5)
  textFields?: string[];                      // Fields for text search
  textBoost?: Record<string, number>;         // Field-specific boosts
  fuzziness?: string | number;                // Fuzzy matching
}
```

### 3.4 ElasticsearchGroundingModule

```typescript
interface GroundingModule {
  retrieve(query: string, options?: GroundingOptions): Promise<GroundingResult>;
}

class ElasticsearchGroundingModule implements GroundingModule {
  constructor(vectorStore: ElasticsearchVectorStore, config?: GroundingConfig);
  
  retrieve(query: string, options?: GroundingOptions): Promise<GroundingResult>;
  formatContext(results: SearchResult[]): string;
}

interface GroundingConfig {
  topK?: number;                              // Default number of results
  minRelevanceScore?: number;                 // Minimum relevance threshold
  includeMetadata?: boolean;                  // Include metadata in context
  contextTemplate?: string;                   // Custom context template
  embedder: EmbeddingProvider;                // Required for query embedding
}

interface GroundingResult {
  context: string;                            // Formatted context for LLM
  sources: GroundingSource[];                 // Source documents
  query: string;                              // Original query
}

interface GroundingSource {
  id: string;
  content: string;
  score: number;
  metadata?: Record<string, unknown>;
}
```

---

## 4. Error Handling

### 4.1 Error Types

```typescript
class ElasticsearchError extends Error {
  constructor(message: string, cause?: Error);
  readonly name = 'ElasticsearchError';
  readonly cause?: Error;
}

class ElasticsearchConnectionError extends ElasticsearchError {
  constructor(message: string, node?: string, cause?: Error);
  readonly node?: string;
}

class ElasticsearchIndexError extends ElasticsearchError {
  constructor(message: string, index: string, cause?: Error);
  readonly index: string;
}

class ElasticsearchQueryError extends ElasticsearchError {
  constructor(message: string, query?: unknown, cause?: Error);
  readonly query?: unknown;
}

class ElasticsearchBulkError extends ElasticsearchError {
  constructor(message: string, errors: BulkItemError[], cause?: Error);
  readonly errors: BulkItemError[];
  readonly failedCount: number;
  readonly successCount: number;
}

class ElasticsearchValidationError extends ElasticsearchError {
  constructor(message: string, field?: string);
  readonly field?: string;
}

interface BulkItemError {
  id: string;
  type: string;
  reason: string;
  status: number;
}
```

### 4.2 Error Mapping

| ES Error | SDK Error | Retryable |
|----------|-----------|-----------|
| `ConnectionError` | `ElasticsearchConnectionError` | Yes |
| `TimeoutError` | `ElasticsearchConnectionError` | Yes |
| `ResponseError (404)` | `ElasticsearchIndexError` | No |
| `ResponseError (400)` | `ElasticsearchQueryError` | No |
| `ResponseError (401/403)` | `ElasticsearchConnectionError` | No |
| `ResponseError (429)` | `ElasticsearchError` | Yes |
| `ResponseError (5xx)` | `ElasticsearchError` | Yes |

---

## 5. Usage Examples

### 5.1 Basic Usage

```typescript
import { ElasticsearchVectorStore } from '@sap-ai-sdk/elasticsearch';

const store = new ElasticsearchVectorStore({
  node: 'https://localhost:9200',
  auth: { apiKey: 'your-api-key' },
  indexName: 'my-documents',
  embeddingDims: 1536,
});

// Initialize (creates index if needed)
await store.initialize();

// Index documents
await store.upsertDocuments([
  {
    id: 'doc1',
    content: 'Introduction to machine learning...',
    embedding: [0.1, 0.2, ...],
    metadata: { category: 'technology', author: 'John' }
  },
  {
    id: 'doc2',
    content: 'Natural language processing basics...',
    embedding: [0.2, 0.3, ...],
    metadata: { category: 'technology', author: 'Jane' }
  }
]);

// Vector search
const results = await store.retrieve(queryEmbedding, {
  k: 5,
  filter: { 'metadata.category': 'technology' }
});
```

### 5.2 Hybrid Search

```typescript
const results = await store.hybridSearch(
  'machine learning introduction',
  queryEmbedding,
  {
    k: 10,
    vectorWeight: 0.7,
    textWeight: 0.3,
    textFields: ['content', 'metadata.title'],
    textBoost: { 'metadata.title': 2.0 }
  }
);
```

### 5.3 With Orchestration

```typescript
import { OrchestrationClient } from '@sap-ai-sdk/orchestration';
import { ElasticsearchGroundingModule } from '@sap-ai-sdk/elasticsearch';

const groundingModule = new ElasticsearchGroundingModule(vectorStore, {
  topK: 5,
  minRelevanceScore: 0.7,
  embedder: embeddingClient
});

const client = new OrchestrationClient({
  grounding: groundingModule
});

const response = await client.chat({
  messages: [{ role: 'user', content: 'What is machine learning?' }],
  useGrounding: true
});
```

### 5.4 Automatic Embedding

```typescript
import { OpenAIEmbeddings } from '@sap-ai-sdk/foundation-models';

const embedder = new OpenAIEmbeddings({
  model: 'text-embedding-3-small'
});

const store = new ElasticsearchVectorStore({
  node: 'https://localhost:9200',
  indexName: 'my-documents',
  embeddingDims: 1536,
  embedder: embedder  // Auto-embed on upsert
});

// Content will be automatically embedded
await store.upsertDocuments([
  { content: 'Document without explicit embedding' }
]);
```

---

## 6. Index Schema

### 6.1 Default Mapping

```json
{
  "mappings": {
    "properties": {
      "content": {
        "type": "text",
        "analyzer": "standard",
        "fields": {
          "keyword": {
            "type": "keyword",
            "ignore_above": 256
          }
        }
      },
      "embedding": {
        "type": "dense_vector",
        "dims": 1536,
        "index": true,
        "similarity": "cosine"
      },
      "metadata": {
        "type": "object",
        "dynamic": true
      },
      "indexed_at": {
        "type": "date"
      }
    }
  },
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 1,
    "index": {
      "knn": true
    }
  }
}
```

### 6.2 Custom Mapping Options

```typescript
interface IndexSettings {
  numberOfShards?: number;
  numberOfReplicas?: number;
  refreshInterval?: string;
  maxResultWindow?: number;
  
  // kNN settings
  knn?: {
    algo_param?: {
      m?: number;                              // HNSW M parameter
      ef_construction?: number;                // HNSW ef_construction
    }
  };
  
  // Custom analyzers
  analyzers?: Record<string, AnalyzerConfig>;
}
```

---

## 7. Performance Considerations

### 7.1 Indexing Performance

| Factor | Recommendation |
|--------|----------------|
| Batch size | 100-1000 documents per bulk request |
| Refresh interval | Set to `-1` during bulk indexing, then refresh |
| Replicas | Set to 0 during bulk indexing |
| Memory | Allocate 50% of available memory to ES |

### 7.2 Search Performance

| Factor | Recommendation |
|--------|----------------|
| `num_candidates` | 10-100x of `k` for better recall |
| Similarity | `cosine` for normalized embeddings |
| Filter before kNN | Use `filter` parameter when possible |
| Shard size | Keep shards < 50GB for optimal performance |

### 7.3 Resource Estimates

| Documents | Dims | Index Size | Memory |
|-----------|------|------------|--------|
| 100K | 1536 | ~1GB | 4GB |
| 1M | 1536 | ~10GB | 16GB |
| 10M | 1536 | ~100GB | 64GB |

---

## 8. Compatibility Matrix

### 8.1 Elasticsearch Versions

| ES Version | Status | Notes |
|------------|--------|-------|
| 8.0 - 8.3 | ✅ | Basic kNN support |
| 8.4 - 8.7 | ✅ | Improved kNN performance |
| 8.8+ | ✅ (Recommended) | HNSW optimizations, byte vectors |
| 7.x | ⚠️ Limited | Requires script_score for vector search |

### 8.2 Deployment Options

| Platform | Support |
|----------|---------|
| Elastic Cloud | ✅ Full support |
| Self-managed | ✅ Full support |
| Amazon OpenSearch | ⚠️ Partial (different API) |
| Azure Elasticsearch | ✅ Full support |

---

## 9. Implementation Plan

### Week 5: Core Implementation (Days 21-25)

| Day | Task | Deliverable |
|-----|------|-------------|
| 21 | Review ES client, kNN API | Technical spec (this doc) |
| 22 | Package structure, dependencies | Scaffolding |
| 23 | ElasticsearchConfig interface | `types.ts` |
| 24 | ElasticsearchVectorStore base | `vector-store.ts` |
| 25 | `upsertDocuments()` with bulk API | Bulk indexing |

### Week 6: Hybrid Search (Days 26-30)

| Day | Task | Deliverable |
|-----|------|-------------|
| 26 | `retrieve()` with kNN search | kNN retrieval |
| 27 | Hybrid search implementation | `hybrid-search.ts` |
| 28 | Configurable boost weights | Search tuning |
| 29 | Metadata filtering | Filter support |
| 30 | Pagination | Pagination |

### Week 7: Orchestration Integration (Days 31-35)

| Day | Task | Deliverable |
|-----|------|-------------|
| 31 | GroundingModule interface design | Interface spec |
| 32 | ElasticsearchGroundingModule | `grounding-module.ts` |
| 33 | Ingest pipeline helpers | `ingest-pipeline.ts` |
| 34 | Automatic embedding via ingest | Embedding pipeline |
| 35 | E2E orchestration tests | Integration tests |

### Week 8: Documentation & Samples (Days 36-40)

| Day | Task | Deliverable |
|-----|------|-------------|
| 36 | Unit tests | Test suite |
| 37 | Integration tests (testcontainers) | Integration tests |
| 38 | README.md, API docs | Documentation |
| 39 | Sample: RAG pipeline | Sample 1 |
| 40 | Sample: Elastic Cloud deployment | Sample 2 |

---

## 10. Appendix

### 10.1 ES Client Reference

```typescript
import { Client } from '@elastic/elasticsearch';

// Create client
const client = new Client({
  node: 'https://localhost:9200',
  auth: { apiKey: 'your-api-key' }
});

// Bulk indexing
await client.bulk({
  refresh: true,
  operations: [
    { index: { _index: 'my-index', _id: '1' } },
    { content: '...', embedding: [...] },
  ]
});

// kNN search
const response = await client.search({
  index: 'my-index',
  knn: {
    field: 'embedding',
    query_vector: [...],
    k: 10,
    num_candidates: 100
  }
});
```

### 10.2 References

- [Elasticsearch kNN Search](https://www.elastic.co/guide/en/elasticsearch/reference/current/knn-search.html)
- [Dense Vector Field](https://www.elastic.co/guide/en/elasticsearch/reference/current/dense-vector.html)
- [Hybrid Search Tutorial](https://www.elastic.co/blog/how-to-deploy-hybrid-search-with-elasticsearch)
- [ES JS Client](https://www.elastic.co/guide/en/elasticsearch/client/javascript-api/current/index.html)