/**
 * @sap-ai-sdk/elasticsearch
 *
 * Elasticsearch vector store integration for SAP AI SDK.
 * Provides kNN search, hybrid search, and RAG integration capabilities.
 *
 * @packageDocumentation
 */

// Types
export type {
  // Configuration
  ElasticsearchAuth,
  ElasticCloudConfig,
  SimilarityMetric,
  EmbeddingProvider,
  ElasticsearchConfig,
  // Documents
  Document,
  IndexedDocument,
  SearchResult,
  // Index
  HnswParams,
  IndexSettings,
  AnalyzerConfig,
  IndexStats,
  // Search
  RetrieveOptions,
  HybridSearchOptions,
  SearchQuery,
  KnnQuery,
  HighlightConfig,
  SortConfig,
  SearchResponse,
  SearchHit,
  // Bulk
  BulkResult,
  BulkItemError,
  // Grounding
  GroundingConfig,
  GroundingOptions,
  GroundingResult,
  GroundingSource,
  // Ingest
  IngestPipelineConfig,
  IngestProcessor,
  InferenceProcessor,
} from './types.js';

// Constants
export {
  DEFAULT_CONFIG,
  DEFAULT_RETRIEVE_OPTIONS,
  DEFAULT_HYBRID_OPTIONS,
  DEFAULT_GROUNDING_CONFIG,
} from './types.js';

// Type guards
export {
  isDocument,
  isIndexedDocument,
  isEmbeddingVector,
  isSimilarityMetric,
} from './types.js';

// Validation utilities
export {
  validateConfig,
  validateDocument,
  validateDocuments,
  validateEmbedding,
  validateRetrieveOptions,
  validateHybridSearchOptions,
  validateIndexSettings,
  normalizeEmbedding,
  isNormalizedEmbedding,
  generateDocumentId,
  sanitizeIndexName,
} from './validation.js';

// Client Factory
export {
  createElasticsearchClient,
  buildIndexMapping,
  testConnection,
  pingCluster,
  getClusterHealth,
  ElasticsearchConfigBuilder,
  configBuilder,
  configFromEnv,
  ConfigPresets,
} from './client-factory.js';

// Errors
export {
  ElasticsearchError,
  ElasticsearchConnectionError,
  ElasticsearchAuthError,
  ElasticsearchTimeoutError,
  ElasticsearchIndexError,
  ElasticsearchIndexNotFoundError,
  ElasticsearchIndexExistsError,
  ElasticsearchQueryError,
  ElasticsearchQuerySyntaxError,
  ElasticsearchBulkError,
  ElasticsearchValidationError,
  ElasticsearchConfigError,
  ElasticsearchEmbeddingError,
  ElasticsearchDocumentNotFoundError,
  // Error utilities
  isElasticsearchError,
  isConnectionError,
  isAuthError,
  isRetryableError,
  createErrorFromResponse,
  wrapError,
} from './errors.js';

// Main classes
export {
  ElasticsearchVectorStore,
  createVectorStore,
  createUninitializedVectorStore,
} from './vector-store.js';

// Bulk operation types
export type {
  UpsertOptions,
  UpsertProgress,
  BulkOperationResult,
  BulkItemErrorInfo,
} from './vector-store.js';

// Hybrid Search
export {
  HybridSearchBuilder,
  createHybridSearch,
  quickKnnSearch,
  quickTextSearch,
  calculateRrfScore,
  mergeResultsWithRrf,
  // Score normalization
  normalizeMinMax,
  normalizeZScore,
  normalizeL2,
  normalizeScores,
  // Fusion functions
  fuseLinear,
  fuseConvex,
  fuseHarmonic,
  // HybridSearcher
  HybridSearcher,
  createHybridSearcher,
  createSemanticSearcher,
  createKeywordSearcher,
  createRrfSearcher,
  createBalancedSearcher,
  // Utilities
  tuneWeights,
  calculateSearchMetrics,
} from './hybrid-search.js';

// Hybrid Search Types
export type {
  KnnRetrieveOptions,
  AdvancedHybridOptions,
  EnhancedSearchResult,
  HybridSearchResponse,
  NormalizationStrategy,
  FusionStrategy,
  HybridSearchConfig,
  HybridSearchResultWithScores,
} from './hybrid-search.js';

// Boost Configuration
export {
  BoostBuilder,
  boostBuilder,
  BoostPresets,
  buildFunctionScoreQuery,
  buildBoostedMultiMatch,
  buildBoostedBoolQuery,
  // Decay functions
  gaussianDecay,
  exponentialDecay,
  linearDecay,
  // Utilities
  combineBoosts,
  clampBoost,
  adjustBoost,
  autoTuneBoosts,
} from './boost-config.js';

// Boost Types
export type {
  FieldBoost,
  QueryBoost,
  TemporalBoost,
  DistanceBoost,
  NumericBoost,
  BoostConfig,
  BoostFunctionType,
  DecayFunction,
  DynamicBoostOptions,
} from './boost-config.js';

// Metadata Filtering
export {
  MetadataFilterBuilder,
  metadataFilter,
  fromObject,
  FilterPresets,
  mergeFilterIntoQuery,
  simpleFilter,
  validateFilter,
} from './metadata-filter.js';

// Metadata Filter Types
export type {
  FilterOperator,
  FilterCondition,
  FilterGroup,
  MetadataFilter,
  PrebuiltFilter,
} from './metadata-filter.js';

// Pagination
export {
  Paginator,
  createPaginator,
  createScrollPaginator,
  createPitPaginator,
  collectAllResults,
  iteratePages,
  processAllResults,
  encodeCursor,
  decodeCursor,
  createCursor,
  toConnection,
  calculatePaginationInfo,
  createPageRange,
} from './pagination.js';

// Pagination Types
export type {
  PaginationStrategy,
  SortDirection,
  SortConfig as PaginationSortConfig,
  PaginationOptions,
  PaginatedResults,
  PageCursor,
  PageInfo,
  Connection,
} from './pagination.js';

// Grounding Module
export {
  ElasticsearchGroundingModule,
  ContextBuilder,
  createGroundingModule,
  createGroundingModuleWithAICore,
  createContextBuilder,
  PromptTemplates,
  buildPrompt,
} from './grounding-module.js';

// Grounding Types
export type {
  GroundingModule,
  GroundingOptions as GroundingModuleOptions,
  GroundingModuleConfig,
  ContextBuilderConfig,
  BuiltContext,
  ContextReference,
  PromptTemplate,
} from './grounding-module.js';

// RAG Chain
export {
  RagChain,
  RagPipelineBuilder,
  RagPipeline,
  createRagChain,
  ragPipeline,
  createSimpleRagChain,
  mergeGroundingResults,
  createReranker,
  createContentFilter,
  createMetadataFilter,
} from './rag-chain.js';

// RAG Chain Types
export type {
  RagChainConfig,
  RagChainResult,
  RagMetrics,
  RagStreamChunk,
  BatchQueryItem,
  BatchResult,
  RagQueryOptions,
  PipelineStepType,
  PipelineStep,
  PipelineContext,
  PipelineResult,
} from './rag-chain.js';

// Ingest Pipeline
export {
  IngestPipelineBuilder,
  PipelineManager,
  PipelinePresets,
  ingestPipeline,
  createPipelineManager,
} from './ingest-pipeline.js';

// Ingest Pipeline Types
export type {
  ProcessorConfig,
  SetProcessorConfig,
  RemoveProcessorConfig,
  RenameProcessorConfig,
  ScriptProcessorConfig,
  ConvertProcessorConfig,
  InferenceProcessorConfig,
  ForeachProcessorConfig,
  AnyProcessorConfig,
  PipelineConfig,
} from './ingest-pipeline.js';

// Embedding Ingest
export {
  TextChunker,
  EmbeddingHelper,
  EmbeddingIngestHelper,
  DocumentProcessor,
  ChunkPresets,
  createChunker,
  createEmbeddingHelper,
  createEmbeddingIngestHelper,
  createDocumentProcessor,
  chunkText,
} from './embedding-ingest.js';

// Embedding Ingest Types
export type {
  ChunkingStrategy,
  ChunkConfig,
  TextChunk,
  EmbedFunction,
  EmbeddingModelConfig,
  EmbeddedDocument,
  IngestDocumentConfig,
} from './embedding-ingest.js';
