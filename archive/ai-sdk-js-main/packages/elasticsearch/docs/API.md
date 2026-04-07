# @sap-ai-sdk/elasticsearch API Reference

Complete API documentation for the Elasticsearch vector store integration.

## Table of Contents

- [Vector Store](#vector-store)
- [Client Factory](#client-factory)
- [Hybrid Search](#hybrid-search)
- [Metadata Filtering](#metadata-filtering)
- [Pagination](#pagination)
- [Boost Configuration](#boost-configuration)
- [Grounding Module](#grounding-module)
- [RAG Chain](#rag-chain)
- [Ingest Pipelines](#ingest-pipelines)
- [Document Processing](#document-processing)
- [Errors](#errors)
- [Types](#types)

---

## Vector Store

### ElasticsearchVectorStore

Main class for vector storage and retrieval operations.

```typescript
class ElasticsearchVectorStore {
  constructor(client: Client, config: ElasticsearchConfig);
  
  // Properties
  readonly indexName: string;
  readonly client: Client;
  
  // Document Operations
  upsertDocuments(docs: Document[], options?: UpsertOptions): Promise<BulkOperationResult>;
  deleteDocument(id: string): Promise<void>;
  deleteDocuments(ids: string[]): Promise<void>;
  deleteByQuery(query: QueryDsl): Promise<DeleteByQueryResult>;
  getDocument(id: string): Promise<IndexedDocument | null>;
  getDocuments(ids: string[]): Promise<IndexedDocument[]>;
  
  // Search Operations
  retrieve(embedding: number[], options?: RetrieveOptions): Promise<SearchResult[]>;
  
  // Index Management
  deleteIndex(): Promise<void>;
}
```

### createVectorStore

Factory function to create and initialize a vector store.

```typescript
function createVectorStore(
  client: Client,
  indexName: string,
  config?: Partial<VectorStoreConfig>
): Promise<ElasticsearchVectorStore>;
```

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `client` | `Client` | Elasticsearch client instance |
| `indexName` | `string` | Name of the index to use |
| `config` | `Partial<VectorStoreConfig>` | Optional configuration |

**Returns:** `Promise<ElasticsearchVectorStore>`

### createUninitializedVectorStore

Create a vector store without initializing the index.

```typescript
function createUninitializedVectorStore(
  client: Client,
  indexName: string,
  config?: Partial<VectorStoreConfig>
): ElasticsearchVectorStore;
```

---

## Client Factory

### createElasticsearchClient

Create an Elasticsearch client with configuration.

```typescript
function createElasticsearchClient(config: ElasticsearchConfig): Client;
```

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `config.node` | `string` | Elasticsearch node URL |
| `config.cloud` | `{ id: string }` | Elastic Cloud configuration |
| `config.auth` | `AuthConfig` | Authentication (apiKey, username/password) |
| `config.tls` | `TlsConfig` | TLS/SSL configuration |
| `config.maxRetries` | `number` | Max retry attempts (default: 3) |
| `config.requestTimeout` | `number` | Request timeout in ms (default: 30000) |

### configFromEnv

Create client configuration from environment variables.

```typescript
function configFromEnv(): ElasticsearchConfig;
```

**Environment Variables:**
| Variable | Description |
|----------|-------------|
| `ES_NODE` | Elasticsearch node URL |
| `ES_CLOUD_ID` | Elastic Cloud deployment ID |
| `ES_API_KEY` | API key for authentication |
| `ES_USERNAME` | Username for basic auth |
| `ES_PASSWORD` | Password for basic auth |

### testConnection

Test connection to Elasticsearch cluster.

```typescript
function testConnection(client: Client): Promise<boolean>;
```

### pingCluster

Ping the cluster and return health status.

```typescript
function pingCluster(client: Client): Promise<ClusterHealth>;
```

### getClusterHealth

Get detailed cluster health information.

```typescript
function getClusterHealth(client: Client): Promise<ClusterHealthResponse>;
```

### buildIndexMapping

Build index mapping for vector storage.

```typescript
function buildIndexMapping(config: IndexMappingConfig): MappingProperties;
```

---

## Hybrid Search

### HybridSearchBuilder

Fluent API for building hybrid search queries.

```typescript
class HybridSearchBuilder {
  // kNN Search
  knn(field: string, vector: number[], k: number, options?: KnnOptions): this;
  
  // Text Search
  text(field: string, query: string, options?: TextOptions): this;
  multiMatch(fields: string[], query: string, options?: MultiMatchOptions): this;
  match(field: string, query: string, options?: MatchOptions): this;
  
  // Filtering
  filter(query: QueryDsl): this;
  must(query: QueryDsl): this;
  should(query: QueryDsl): this;
  mustNot(query: QueryDsl): this;
  
  // Result Fusion
  withRrf(k?: number): this;
  
  // Pagination & Sorting
  paginate(from: number, size: number): this;
  sort(config: SortConfig[]): this;
  
  // Highlighting
  highlight(field: string, options?: HighlightOptions): this;
  
  // Build
  build(): SearchRequest;
}
```

### createHybridSearch

Factory function for HybridSearchBuilder.

```typescript
function createHybridSearch(): HybridSearchBuilder;
```

### HybridSearcher

Pre-configured hybrid searcher class.

```typescript
class HybridSearcher {
  constructor(client: Client, indexName: string, config: HybridSearchConfig);
  
  search(query: string, embedding: number[], options?: SearchOptions): Promise<SearchResult[]>;
  knnOnly(embedding: number[], k: number): Promise<SearchResult[]>;
  textOnly(query: string): Promise<SearchResult[]>;
}
```

### Score Normalization Functions

```typescript
function normalizeMinMax(scores: number[]): number[];
function normalizeZScore(scores: number[]): number[];
function normalizeL2(scores: number[]): number[];
function normalizeScores(scores: number[], strategy: NormalizationStrategy): number[];
```

### RRF Functions

```typescript
function calculateRrfScore(ranks: number[], k?: number): number;
function mergeResultsWithRrf(results: SearchResult[][], k?: number): SearchResult[];
```

---

## Metadata Filtering

### MetadataFilterBuilder

Fluent API for building metadata filters.

```typescript
class MetadataFilterBuilder {
  // Term Filters
  term(field: string, value: string | number | boolean): this;
  terms(field: string, values: (string | number)[]): this;
  
  // Range Filters
  range(field: string, range: RangeQuery): this;
  dateRange(field: string, from: Date | string, to: Date | string): this;
  
  // Existence
  exists(field: string): this;
  missing(field: string): this;
  
  // Boolean Composition
  must(fn: (builder: MetadataFilterBuilder) => MetadataFilterBuilder): this;
  should(fn: (builder: MetadataFilterBuilder) => MetadataFilterBuilder): this;
  mustNot(fn: (builder: MetadataFilterBuilder) => MetadataFilterBuilder): this;
  
  // Convenience
  source(value: string): this;
  category(value: string): this;
  
  // Build
  build(): BoolQuery;
}
```

### metadataFilter

Factory function for MetadataFilterBuilder.

```typescript
function metadataFilter(): MetadataFilterBuilder;
```

### FilterPresets

Pre-built filter configurations.

```typescript
const FilterPresets = {
  recentDocuments(dateField: string, days: number): BoolQuery;
  highPriority(field: string, minPriority: number): BoolQuery;
  bySource(source: string): BoolQuery;
  byCategory(category: string): BoolQuery;
  publishedOnly(): BoolQuery;
};
```

### simpleFilter

Create a simple term filter.

```typescript
function simpleFilter(field: string, value: string | number): BoolQuery;
```

### validateFilter

Validate a filter query structure.

```typescript
function validateFilter(filter: unknown): filter is BoolQuery;
```

---

## Pagination

### Paginator

Generic paginator class.

```typescript
class Paginator<T> implements AsyncIterable<PaginatedResults<T>> {
  constructor(client: Client, indexName: string, options: PaginationOptions);
  
  // Navigation
  nextPage(): Promise<PaginatedResults<T> | null>;
  previousPage(): Promise<PaginatedResults<T> | null>;
  getPage(pageNumber: number): Promise<PaginatedResults<T> | null>;
  
  // Async iteration
  [Symbol.asyncIterator](): AsyncIterator<PaginatedResults<T>>;
  
  // State
  readonly currentPage: number;
  readonly totalPages: number;
  readonly hasNextPage: boolean;
  readonly hasPreviousPage: boolean;
}
```

### Factory Functions

```typescript
function createPaginator<T>(
  client: Client,
  indexName: string,
  options: PaginationOptions
): Paginator<T>;

function createScrollPaginator<T>(
  client: Client,
  indexName: string,
  options: ScrollOptions
): Paginator<T>;

function createPitPaginator<T>(
  client: Client,
  indexName: string,
  options: PitOptions
): Paginator<T>;
```

### Utility Functions

```typescript
// Collect all results from paginator
function collectAllResults<T>(paginator: Paginator<T>): Promise<T[]>;

// Iterate through pages
function iteratePages<T>(paginator: Paginator<T>): AsyncIterable<PaginatedResults<T>>;

// Process all results with callback
function processAllResults<T>(
  paginator: Paginator<T>,
  processor: (results: T[]) => Promise<void>
): Promise<void>;

// Calculate pagination info
function calculatePaginationInfo(
  total: number,
  page: number,
  pageSize: number
): PaginationInfo;
```

### Cursor Functions

```typescript
function encodeCursor(data: CursorData): string;
function decodeCursor(cursor: string): CursorData;
function createCursor(sort: SortValue[]): PageCursor;
function toConnection<T>(results: PaginatedResults<T>): Connection<T>;
```

---

## Boost Configuration

### BoostBuilder

Fluent API for configuring relevance boosts.

```typescript
class BoostBuilder {
  // Field Boosts
  field(name: string, boost: number): this;
  
  // Temporal Boosts
  recency(field: string, config: RecencyConfig): this;
  
  // Distance Boosts
  proximity(field: string, config: ProximityConfig): this;
  
  // Numeric Boosts
  numeric(field: string, config: NumericBoostConfig): this;
  
  // Build
  build(): BoostConfig;
}
```

### BoostPresets

Pre-configured boost settings.

```typescript
const BoostPresets = {
  balanced(): BoostConfig;
  semantic(): BoostConfig;
  keyword(): BoostConfig;
  recencyBiased(dateField: string, decayDays: number): BoostConfig;
  ecommerce(): BoostConfig;
  documentation(): BoostConfig;
  news(): BoostConfig;
};
```

### Decay Functions

```typescript
function gaussianDecay(origin: number, scale: number, decay: number): DecayFunction;
function exponentialDecay(origin: number, scale: number, decay: number): DecayFunction;
function linearDecay(origin: number, scale: number, decay: number): DecayFunction;
```

### Query Building

```typescript
function buildFunctionScoreQuery(baseQuery: QueryDsl, boosts: BoostConfig): QueryDsl;
function buildBoostedMultiMatch(fields: string[], query: string, boosts: FieldBoost[]): QueryDsl;
function buildBoostedBoolQuery(clauses: BoolClause[], boosts: QueryBoost[]): QueryDsl;
```

---

## Grounding Module

### ElasticsearchGroundingModule

Grounding module for RAG integration.

```typescript
class ElasticsearchGroundingModule implements GroundingModule {
  constructor(client: Client, indexName: string, config: GroundingModuleConfig);
  
  ground(query: string, options?: GroundingOptions): Promise<GroundingResult>;
}
```

### createGroundingModule

Factory function for grounding module.

```typescript
function createGroundingModule(
  client: Client,
  indexName: string,
  config: GroundingModuleConfig
): ElasticsearchGroundingModule;
```

### ContextBuilder

Build context from grounding results.

```typescript
class ContextBuilder {
  constructor(config?: ContextBuilderConfig);
  
  build(result: GroundingResult): BuiltContext;
}
```

### createContextBuilder

```typescript
function createContextBuilder(config?: ContextBuilderConfig): ContextBuilder;
```

### PromptTemplates

Pre-built prompt templates.

```typescript
const PromptTemplates = {
  default: PromptTemplate;
  technical: PromptTemplate;
  qaWithSources: PromptTemplate;
  conversational: PromptTemplate;
  strict: PromptTemplate;
};

function buildPrompt(
  template: PromptTemplate,
  query: string,
  context: BuiltContext
): { system: string; user: string };
```

---

## RAG Chain

### RagChain

Complete RAG pipeline implementation.

```typescript
class RagChain {
  constructor(config: RagChainConfig);
  
  // Query methods
  query(query: string, options?: RagQueryOptions): Promise<RagChainResult>;
  queryStream(query: string, options?: RagQueryOptions): AsyncIterable<RagStreamChunk>;
  batchQuery(queries: BatchQueryItem[], options?: BatchOptions): Promise<BatchResult[]>;
  
  // Cache management
  clearCache(): void;
  getCacheStats(): CacheStats;
  
  // Metrics
  getMetrics(): RagMetrics;
  resetMetrics(): void;
}
```

### createRagChain

```typescript
function createRagChain(config: RagChainConfig): RagChain;
```

### RagPipelineBuilder

Fluent API for building custom RAG pipelines.

```typescript
class RagPipelineBuilder {
  preprocess(name: string, fn: (query: string) => Promise<string>): this;
  ground(module: GroundingModule, options?: GroundingOptions): this;
  filter(name: string, fn: (sources: GroundingSource[]) => GroundingSource[]): this;
  rank(name: string, fn: (query: string, sources: GroundingSource[]) => Promise<GroundingSource[]>): this;
  buildContext(builder: ContextBuilder): this;
  buildPrompt(template: PromptTemplate): this;
  
  build(): RagPipeline;
}

function ragPipeline(): RagPipelineBuilder;
```

### Utility Functions

```typescript
function mergeGroundingResults(
  results: GroundingResult[],
  options?: MergeOptions
): GroundingResult;

function createReranker(
  fn: (query: string, sources: GroundingSource[]) => Promise<GroundingSource[]>
): Reranker;

function createContentFilter(
  predicate: (content: string) => boolean
): ContentFilter;
```

---

## Ingest Pipelines

### IngestPipelineBuilder

Fluent API for building ingest pipelines.

```typescript
class IngestPipelineBuilder {
  // Metadata
  describe(description: string): this;
  version(version: number): this;
  
  // Processors
  set(field: string, value: string): this;
  remove(field: string): this;
  rename(field: string, targetField: string): this;
  convert(field: string, type: string): this;
  trim(field: string): this;
  lowercase(field: string): this;
  uppercase(field: string): this;
  split(field: string, separator: string): this;
  join(field: string, separator: string): this;
  gsub(field: string, pattern: string, replacement: string): this;
  script(source: string, params?: Record<string, unknown>): this;
  
  // Conditional
  conditionalSet(condition: string, field: string, value: string): this;
  
  // ML Inference
  inference(modelId: string, config: InferenceConfig): this;
  
  // Iteration
  foreach(field: string, processor: ProcessorConfig): this;
  
  // Error handling
  onFailure(processor: ProcessorConfig): this;
  
  // Build
  build(): PipelineConfig;
}
```

### ingestPipeline

Factory function for IngestPipelineBuilder.

```typescript
function ingestPipeline(): IngestPipelineBuilder;
```

### PipelinePresets

Pre-built pipeline configurations.

```typescript
const PipelinePresets = {
  textProcessing(): IngestPipelineBuilder;
  embedding(modelId: string): IngestPipelineBuilder;
  elserEmbedding(): IngestPipelineBuilder;
  ragDocument(modelId: string): IngestPipelineBuilder;
  chunkedDocument(modelId: string, chunkField?: string): IngestPipelineBuilder;
};
```

### PipelineManager

Manage ingest pipelines.

```typescript
class PipelineManager {
  constructor(client: Client);
  
  create(name: string, pipeline: PipelineConfig): Promise<void>;
  get(name: string): Promise<PipelineConfig | null>;
  delete(name: string): Promise<void>;
  list(): Promise<string[]>;
  exists(name: string): Promise<boolean>;
  simulate(name: string, docs: SimulateDoc[]): Promise<SimulateResult>;
  setIndexPipeline(indexName: string, pipelineName: string): Promise<void>;
}

function createPipelineManager(client: Client): PipelineManager;
```

---

## Document Processing

### TextChunker

Text chunking utilities.

```typescript
class TextChunker {
  constructor(config?: ChunkConfig);
  
  chunk(text: string): TextChunk[];
}

function createChunker(config?: ChunkConfig): TextChunker;
function chunkText(text: string, config?: ChunkConfig): TextChunk[];
```

**ChunkConfig:**
| Property | Type | Description |
|----------|------|-------------|
| `strategy` | `ChunkingStrategy` | 'fixed' \| 'sentence' \| 'paragraph' \| 'recursive' \| 'semantic' |
| `chunkSize` | `number` | Target chunk size in characters |
| `chunkOverlap` | `number` | Overlap between chunks |
| `minChunkSize` | `number` | Minimum chunk size |
| `separators` | `string[]` | Custom separators |
| `addMetadata` | `boolean` | Include chunk metadata |

### ChunkPresets

```typescript
const ChunkPresets = {
  small: ChunkConfig;    // 500 chars, 100 overlap
  medium: ChunkConfig;   // 1000 chars, 200 overlap
  large: ChunkConfig;    // 2000 chars, 400 overlap
  sentence: ChunkConfig; // Sentence-based
  paragraph: ChunkConfig;// Paragraph-based
  code: ChunkConfig;     // Code-aware
};
```

### EmbeddingHelper

Batch embedding generation.

```typescript
class EmbeddingHelper {
  constructor(config: EmbeddingModelConfig);
  
  embed(texts: string[]): Promise<number[][]>;
  embedSingle(text: string): Promise<number[]>;
  embedDocuments(docs: Document[], options?: EmbedOptions): Promise<EmbeddedDocument[]>;
}

function createEmbeddingHelper(config: EmbeddingModelConfig): EmbeddingHelper;
```

### DocumentProcessor

Complete document processing (chunk + embed).

```typescript
class DocumentProcessor {
  constructor(config: DocumentProcessorConfig);
  
  process(doc: Document, options?: ProcessOptions): Promise<EmbeddedDocument[]>;
  processMany(docs: Document[], options?: ProcessManyOptions): Promise<EmbeddedDocument[]>;
}

function createDocumentProcessor(config: DocumentProcessorConfig): DocumentProcessor;
```

---

## Errors

### Error Classes

| Class | Description |
|-------|-------------|
| `ElasticsearchError` | Base error class |
| `ElasticsearchConnectionError` | Connection failures |
| `ElasticsearchAuthError` | Authentication failures |
| `ElasticsearchTimeoutError` | Request timeouts |
| `ElasticsearchIndexError` | Index operation errors |
| `ElasticsearchIndexNotFoundError` | Index not found |
| `ElasticsearchIndexExistsError` | Index already exists |
| `ElasticsearchQueryError` | Query execution errors |
| `ElasticsearchQuerySyntaxError` | Invalid query syntax |
| `ElasticsearchBulkError` | Bulk operation errors |
| `ElasticsearchValidationError` | Validation failures |
| `ElasticsearchConfigError` | Configuration errors |
| `ElasticsearchEmbeddingError` | Embedding failures |
| `ElasticsearchDocumentNotFoundError` | Document not found |

### Error Utilities

```typescript
function isElasticsearchError(error: unknown): error is ElasticsearchError;
function isConnectionError(error: unknown): error is ElasticsearchConnectionError;
function isAuthError(error: unknown): error is ElasticsearchAuthError;
function isRetryableError(error: unknown): boolean;
function createErrorFromResponse(response: ErrorResponse): ElasticsearchError;
function wrapError(error: unknown, context?: string): ElasticsearchError;
```

---

## Types

### Document Types

```typescript
interface Document {
  id?: string;
  content: string;
  embedding: number[];
  metadata?: Record<string, unknown>;
}

interface IndexedDocument extends Document {
  id: string;
}

interface SearchResult extends IndexedDocument {
  score: number;
  highlights?: Record<string, string[]>;
}
```

### Configuration Types

```typescript
interface ElasticsearchConfig {
  node?: string;
  cloud?: { id: string };
  auth?: AuthConfig;
  indexName: string;
  embeddingDims: number;
  similarity?: SimilarityMetric;
  maxRetries?: number;
  requestTimeout?: number;
}

type SimilarityMetric = 'cosine' | 'dot_product' | 'l2_norm';

interface AuthConfig {
  apiKey?: string;
  username?: string;
  password?: string;
}
```

### Search Types

```typescript
interface RetrieveOptions {
  k?: number;
  minScore?: number;
  filter?: QueryDsl;
  includeEmbedding?: boolean;
  includeHighlights?: boolean;
}

interface HybridSearchOptions {
  vectorWeight?: number;
  textWeight?: number;
  rrfK?: number;
  minScore?: number;
}

interface SearchResponse<T> {
  hits: T[];
  total: number;
  took: number;
  maxScore?: number;
}
```

### Grounding Types

```typescript
interface GroundingResult {
  sources: GroundingSource[];
  took: number;
  query?: string;
}

interface GroundingSource {
  id: string;
  content: string;
  score: number;
  metadata?: Record<string, unknown>;
}

interface GroundingOptions {
  topK?: number;
  minScore?: number;
  filter?: QueryDsl;
  useHybrid?: boolean;
  hybridOptions?: HybridSearchOptions;
}
```

### Pagination Types

```typescript
type PaginationStrategy = 'from-size' | 'search-after' | 'scroll' | 'pit';

interface PaginationOptions {
  strategy: PaginationStrategy;
  pageSize: number;
  query?: QueryDsl;
  sort?: SortConfig[];
}

interface PaginatedResults<T> {
  results: T[];
  pageNumber: number;
  pageSize: number;
  total: number;
  hasNextPage: boolean;
  hasPreviousPage: boolean;
}

interface PageInfo {
  startCursor?: string;
  endCursor?: string;
  hasNextPage: boolean;
  hasPreviousPage: boolean;
}
```

### Type Guards

```typescript
function isDocument(value: unknown): value is Document;
function isIndexedDocument(value: unknown): value is IndexedDocument;
function isEmbeddingVector(value: unknown): value is number[];
function isSimilarityMetric(value: unknown): value is SimilarityMetric;
```

### Validation Functions

```typescript
function validateConfig(config: unknown): asserts config is ElasticsearchConfig;
function validateDocument(doc: unknown): asserts doc is Document;
function validateDocuments(docs: unknown): asserts docs is Document[];
function validateEmbedding(embedding: unknown): asserts embedding is number[];
function validateRetrieveOptions(options: unknown): asserts options is RetrieveOptions;
function validateIndexSettings(settings: unknown): asserts settings is IndexSettings;
function normalizeEmbedding(embedding: number[]): number[];
function isNormalizedEmbedding(embedding: number[], tolerance?: number): boolean;
function generateDocumentId(): string;
function sanitizeIndexName(name: string): string;