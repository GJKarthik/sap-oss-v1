# @sap-ai-sdk/elasticsearch

Elasticsearch vector store integration for SAP AI SDK. Provides kNN search, hybrid search, and RAG integration capabilities.

[![npm version](https://badge.fury.io/js/@sap-ai-sdk%2Felasticsearch.svg)](https://www.npmjs.com/package/@sap-ai-sdk/elasticsearch)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

## Features

- 🔍 **Vector Search** - High-performance kNN search using Elasticsearch's dense_vector type
- 🔄 **Hybrid Search** - Combine vector similarity with BM25 text search
- 📊 **Relevance Tuning** - Configurable boost weights and scoring functions
- 🏷️ **Metadata Filtering** - Filter results by document metadata
- 📄 **Pagination** - Multiple pagination strategies (from/size, search_after, scroll, PIT)
- 🤖 **RAG Integration** - Built-in grounding module and RAG chain support
- 📥 **Ingest Pipelines** - Automatic document processing and embedding generation

## Installation

```bash
npm install @sap-ai-sdk/elasticsearch
# or
pnpm add @sap-ai-sdk/elasticsearch
# or
yarn add @sap-ai-sdk/elasticsearch
```

## Prerequisites

- Elasticsearch 8.x or higher
- Node.js 18+ 
- For local development: Docker (for running Elasticsearch)

## Quick Start

### 1. Create a Vector Store

```typescript
import { 
  createElasticsearchClient, 
  createVectorStore 
} from '@sap-ai-sdk/elasticsearch';

// Create ES client
const client = createElasticsearchClient({
  node: 'http://localhost:9200',
  // For Elastic Cloud:
  // cloud: { id: 'my-deployment:xxxx' },
  // auth: { apiKey: 'your-api-key' },
});

// Create vector store
const vectorStore = await createVectorStore(client, 'my-documents', {
  embeddingDimension: 1536,
  similarity: 'cosine',
});
```

### 2. Index Documents

```typescript
// Single document
await vectorStore.upsertDocuments([{
  id: 'doc-1',
  content: 'Introduction to machine learning...',
  embedding: await generateEmbedding('Introduction to machine learning...'),
  metadata: {
    source: 'docs',
    category: 'AI',
    createdAt: new Date().toISOString(),
  },
}]);

// Bulk indexing
const documents = [
  { id: 'doc-1', content: '...', embedding: [...], metadata: {...} },
  { id: 'doc-2', content: '...', embedding: [...], metadata: {...} },
  // ... more documents
];

const result = await vectorStore.upsertDocuments(documents, {
  batchSize: 100,
  onProgress: (progress) => console.log(`${progress.percent}% complete`),
});

console.log(`Indexed: ${result.totalIndexed}, Failed: ${result.totalFailed}`);
```

### 3. Retrieve Similar Documents

```typescript
// kNN search
const queryEmbedding = await generateEmbedding('What is machine learning?');
const results = await vectorStore.retrieve(queryEmbedding, {
  k: 10,
  minScore: 0.7,
});

results.forEach((doc) => {
  console.log(`${doc.id}: ${doc.score} - ${doc.content.slice(0, 100)}...`);
});
```

## Hybrid Search

Combine vector similarity with traditional text search for better results:

```typescript
import { createHybridSearch } from '@sap-ai-sdk/elasticsearch';

// Build a hybrid search query
const builder = createHybridSearch()
  .knn('embedding', queryEmbedding, 10, { numCandidates: 50 })
  .text('content', 'machine learning fundamentals')
  .filter({ term: { 'metadata.category': 'AI' } })
  .withRrf(60);  // RRF fusion with k=60

const query = builder.build();
const results = await client.search({ index: 'my-documents', ...query });
```

### Hybrid Search Builder

```typescript
import { HybridSearchBuilder } from '@sap-ai-sdk/elasticsearch';

const search = new HybridSearchBuilder()
  // Add kNN search
  .knn('embedding', embedding, 10, {
    numCandidates: 100,
    filter: { term: { status: 'published' } },
  })
  // Add text search with boost
  .text('content', query, { boost: 0.8 })
  // Add multi-match for multiple fields
  .multiMatch(['title', 'content'], query, { type: 'best_fields' })
  // Apply metadata filter
  .filter({ range: { 'metadata.date': { gte: 'now-30d' } } })
  // Add highlighting
  .highlight('content', { pre_tags: ['<b>'], post_tags: ['</b>'] })
  // Configure pagination
  .paginate(0, 20)
  // Build the query
  .build();
```

## Metadata Filtering

Filter search results by document metadata:

```typescript
import { metadataFilter, FilterPresets } from '@sap-ai-sdk/elasticsearch';

// Fluent API
const filter = metadataFilter()
  .term('category', 'technology')
  .range('priority', { gte: 3 })
  .dateRange('createdAt', new Date('2024-01-01'), new Date())
  .exists('metadata.author')
  .build();

// Use with retrieve
const results = await vectorStore.retrieve(embedding, {
  k: 10,
  filter: filter,
});

// Preset filters
const recentDocs = FilterPresets.recentDocuments('metadata.createdAt', 30);
const highPriority = FilterPresets.highPriority('metadata.priority', 4);
```

### Filter Builder

```typescript
import { MetadataFilterBuilder } from '@sap-ai-sdk/elasticsearch';

const filter = new MetadataFilterBuilder()
  .term('source', 'wikipedia')
  .terms('tags', ['ai', 'ml', 'nlp'])
  .range('score', { gte: 0.8, lte: 1.0 })
  .dateRange('published', '2024-01-01', '2024-12-31')
  .must(builder => builder.exists('author'))
  .should(builder => builder.term('featured', true))
  .mustNot(builder => builder.term('status', 'draft'))
  .build();
```

## Pagination

Multiple pagination strategies for different use cases:

```typescript
import { 
  createPaginator, 
  createScrollPaginator, 
  createPitPaginator 
} from '@sap-ai-sdk/elasticsearch';

// From/Size pagination (simple, small datasets)
const paginator = createPaginator(client, 'my-index', {
  strategy: 'from-size',
  pageSize: 20,
});

// Cursor-based pagination (efficient, no deep pagination limit)
const cursorPaginator = createPaginator(client, 'my-index', {
  strategy: 'search-after',
  pageSize: 100,
  sort: [{ createdAt: 'desc' }, { _id: 'asc' }],
});

// Scroll API (for processing all documents)
const scrollPaginator = createScrollPaginator(client, 'my-index', {
  scrollTtl: '5m',
  batchSize: 1000,
});

// Point-in-Time (consistent snapshots)
const pitPaginator = createPitPaginator(client, 'my-index', {
  keepAlive: '1m',
});

// Iterate through pages
for await (const page of paginator) {
  console.log(`Page ${page.pageNumber}: ${page.results.length} results`);
}

// Collect all results
const allResults = await collectAllResults(paginator);
```

## Boost Configuration

Configure relevance scoring with field boosts and decay functions:

```typescript
import { BoostBuilder, BoostPresets } from '@sap-ai-sdk/elasticsearch';

// Custom boost configuration
const boost = new BoostBuilder()
  .field('title', 2.0)
  .field('content', 1.0)
  .field('summary', 1.5)
  .recency('createdAt', { scale: '30d', decay: 0.5 })
  .proximity('location', { origin: [0, 0], scale: '10km' })
  .numeric('priority', { factor: 1.2 })
  .build();

// Use presets
const balanced = BoostPresets.balanced();
const recencyBiased = BoostPresets.recencyBiased('updatedAt', 14);
const semantic = BoostPresets.semantic();
```

## RAG Integration

### Grounding Module

Integrate with SAP AI SDK orchestration:

```typescript
import { 
  createGroundingModule, 
  createContextBuilder,
  PromptTemplates 
} from '@sap-ai-sdk/elasticsearch';

// Create grounding module
const grounding = createGroundingModule(client, 'knowledge-base', {
  embedFn: async (text) => generateEmbedding(text),
  defaultOptions: {
    k: 5,
    minScore: 0.7,
  },
});

// Ground a query
const result = await grounding.ground('What is RAG?', {
  topK: 5,
  useHybrid: true,
});

// Build context for LLM
const contextBuilder = createContextBuilder({
  maxContextLength: 8000,
  referenceFormat: 'numbered',  // [1], [2], etc.
});

const context = contextBuilder.build(result);
console.log(context.context);
console.log(context.references);

// Build prompt
const prompt = PromptTemplates.qaWithSources.build('What is RAG?', context);
console.log(prompt.system);
console.log(prompt.user);
```

### RAG Chain

Complete RAG pipeline with caching and metrics:

```typescript
import { createRagChain, ragPipeline } from '@sap-ai-sdk/elasticsearch';

// Simple RAG chain
const ragChain = createRagChain({
  grounding,
  contextBuilder: createContextBuilder(),
  enableCache: true,
  cacheTtl: 300000,  // 5 minutes
  enableMetrics: true,
});

// Query
const result = await ragChain.query('Explain vector search');
console.log(result.prompt);
console.log(result.sources);
console.log(result.metrics);

// Streaming
for await (const chunk of ragChain.queryStream('What is kNN?')) {
  if (chunk.type === 'source') {
    console.log('Found source:', chunk.source.id);
  } else if (chunk.type === 'done') {
    console.log('Complete:', chunk.result);
  }
}

// Batch queries
const results = await ragChain.batchQuery([
  { id: '1', query: 'What is ML?' },
  { id: '2', query: 'What is DL?' },
], { concurrency: 3 });

// Custom pipeline
const pipeline = ragPipeline()
  .preprocess('normalize', async (q) => q.toLowerCase().trim())
  .ground(grounding, { topK: 10 })
  .filter('minLength', (sources) => sources.filter(s => s.content.length > 100))
  .rank('rerank', async (query, sources) => customRerank(query, sources))
  .buildContext(createContextBuilder())
  .buildPrompt(PromptTemplates.technical)
  .build();

const result = await pipeline.execute('my query');
```

## Ingest Pipelines

Create Elasticsearch ingest pipelines for document processing:

```typescript
import { 
  ingestPipeline, 
  PipelinePresets,
  createPipelineManager 
} from '@sap-ai-sdk/elasticsearch';

// Build a custom pipeline
const pipeline = ingestPipeline()
  .describe('Text processing pipeline')
  .set('@timestamp', '{{_ingest.timestamp}}')
  .trim('content')
  .lowercase('content')
  .inference('my-embedding-model', {
    inputField: 'content',
    outputField: 'embedding',
  })
  .build();

// Use presets
const textPipeline = PipelinePresets.textProcessing();
const ragPipeline = PipelinePresets.ragDocument('my-model');
const elserPipeline = PipelinePresets.elserEmbedding();

// Pipeline Manager
const manager = createPipelineManager(client);

// Create pipeline
await manager.create('my-pipeline', pipeline);

// List pipelines
const pipelines = await manager.list();

// Test pipeline
const testResult = await manager.simulate('my-pipeline', [
  { _source: { content: 'Test document' } },
]);

// Apply to index
await manager.setIndexPipeline('my-index', 'my-pipeline');
```

## Document Processing & Chunking

Process documents with chunking and embedding:

```typescript
import { 
  createChunker, 
  createEmbeddingHelper,
  createDocumentProcessor,
  ChunkPresets 
} from '@sap-ai-sdk/elasticsearch';

// Text chunking
const chunker = createChunker({
  strategy: 'recursive',
  chunkSize: 1000,
  chunkOverlap: 200,
});

const chunks = chunker.chunk(longDocument);

// Use presets
const smallChunks = ChunkPresets.small;   // 500 chars
const mediumChunks = ChunkPresets.medium; // 1000 chars
const codeChunks = ChunkPresets.code;     // Function-aware

// Embedding helper
const embedHelper = createEmbeddingHelper({
  dimension: 1536,
  batchSize: 32,
  embedFn: async (texts) => myEmbeddingAPI.embed(texts),
});

const embeddings = await embedHelper.embed(['text1', 'text2']);

// Document processor (chunk + embed)
const processor = createDocumentProcessor({
  chunkConfig: ChunkPresets.medium,
  embeddingConfig: {
    dimension: 1536,
    embedFn: myEmbedFn,
  },
});

const processedDocs = await processor.processMany(documents, {
  chunk: true,
  embed: true,
  concurrency: 5,
});
```

## Error Handling

```typescript
import {
  ElasticsearchError,
  ElasticsearchConnectionError,
  ElasticsearchIndexNotFoundError,
  ElasticsearchQueryError,
  isElasticsearchError,
  isRetryableError,
} from '@sap-ai-sdk/elasticsearch';

try {
  const results = await vectorStore.retrieve(embedding);
} catch (error) {
  if (isElasticsearchError(error)) {
    if (error instanceof ElasticsearchConnectionError) {
      console.error('Connection failed:', error.message);
    } else if (error instanceof ElasticsearchIndexNotFoundError) {
      console.error('Index not found:', error.indexName);
    } else if (error instanceof ElasticsearchQueryError) {
      console.error('Query failed:', error.query);
    }
    
    if (isRetryableError(error)) {
      // Retry the operation
    }
  }
  throw error;
}
```

## Configuration

### Client Configuration

```typescript
import { createElasticsearchClient, configFromEnv } from '@sap-ai-sdk/elasticsearch';

// Manual configuration
const client = createElasticsearchClient({
  node: 'http://localhost:9200',
  auth: {
    username: 'elastic',
    password: 'password',
  },
  tls: {
    rejectUnauthorized: false,
  },
  maxRetries: 3,
  requestTimeout: 30000,
});

// Elastic Cloud
const cloudClient = createElasticsearchClient({
  cloud: { id: 'my-deployment:xxxx' },
  auth: { apiKey: 'your-api-key' },
});

// From environment variables
const envClient = configFromEnv();
// Uses: ES_NODE, ES_CLOUD_ID, ES_API_KEY, ES_USERNAME, ES_PASSWORD
```

### Vector Store Configuration

```typescript
const vectorStore = await createVectorStore(client, 'my-index', {
  // Vector configuration
  embeddingDimension: 1536,
  similarity: 'cosine',  // 'cosine' | 'dot_product' | 'l2_norm'
  
  // Field names
  contentField: 'content',
  embeddingField: 'embedding',
  metadataField: 'metadata',
  
  // Index settings
  numberOfShards: 1,
  numberOfReplicas: 1,
  
  // HNSW parameters
  hnswParams: {
    m: 16,
    efConstruction: 100,
  },
});
```

## API Reference

See [docs/API.md](./docs/API.md) for complete API documentation.

### Main Exports

| Export | Description |
|--------|-------------|
| `ElasticsearchVectorStore` | Main vector store class |
| `createVectorStore` | Factory function for vector store |
| `createElasticsearchClient` | Factory function for ES client |
| `HybridSearchBuilder` | Fluent API for hybrid search |
| `MetadataFilterBuilder` | Fluent API for metadata filters |
| `Paginator` | Pagination utilities |
| `ElasticsearchGroundingModule` | RAG grounding adapter |
| `RagChain` | Complete RAG pipeline |
| `IngestPipelineBuilder` | Ingest pipeline builder |
| `TextChunker` | Document chunking |
| `EmbeddingHelper` | Embedding generation |

## Testing

```bash
# Unit tests
npm test

# Integration tests (requires Elasticsearch)
docker-compose -f tests/docker-compose.test.yml up -d
npm run test:integration

# All tests
npm run test:all
```

## Troubleshooting

### Connection Issues

**Error: `ECONNREFUSED`**
```
Elasticsearch is not running or not accessible at the specified URL.
```
Solution: Start Elasticsearch or verify the URL is correct.

**Error: `certificate has expired`**
```
TLS certificate validation failed.
```
Solution: Update certificates or disable verification for development:
```typescript
{ tls: { rejectUnauthorized: false } }
```

### Index Issues

**Error: `index_not_found_exception`**
```
The specified index does not exist.
```
Solution: Create the index first or use `createVectorStore` which auto-creates.

### Search Issues

**Error: `query_shard_exception`**
```
The kNN query dimension doesn't match the index mapping.
```
Solution: Ensure embedding dimension matches `embeddingDimension` in config.

## License

Apache-2.0 - see [LICENSE](./LICENSE) for details.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines.