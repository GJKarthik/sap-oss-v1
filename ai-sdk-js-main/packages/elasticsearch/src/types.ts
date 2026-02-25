/**
 * @sap-ai-sdk/elasticsearch - Type Definitions
 *
 * Types and interfaces for Elasticsearch vector store integration.
 */

// ============================================================================
// Configuration Types
// ============================================================================

/**
 * Authentication options for Elasticsearch
 */
export interface ElasticsearchAuth {
  /** Username for basic auth */
  username?: string;
  /** Password for basic auth */
  password?: string;
  /** API key for authentication */
  apiKey?: string | { id: string; api_key: string };
  /** Bearer token */
  bearer?: string;
}

/**
 * Elastic Cloud configuration
 */
export interface ElasticCloudConfig {
  /** Elastic Cloud deployment ID */
  id: string;
}

/**
 * Similarity metrics for vector search
 */
export type SimilarityMetric = 'cosine' | 'dot_product' | 'l2_norm';

/**
 * Embedding provider interface for automatic embedding
 */
export interface EmbeddingProvider {
  /** Embed multiple texts into vectors */
  embed(texts: string[]): Promise<number[][]>;
  /** Get the embedding dimensions */
  getDimensions(): number;
}

/**
 * Configuration for ElasticsearchVectorStore
 */
export interface ElasticsearchConfig {
  // Connection
  /** Elasticsearch node URL(s) */
  node: string | string[];
  /** Elastic Cloud configuration */
  cloud?: ElasticCloudConfig;
  /** Authentication credentials */
  auth?: ElasticsearchAuth;

  // Index settings
  /** Target index name */
  indexName: string;

  // Vector settings
  /** Vector dimensions (e.g., 1536 for OpenAI embeddings) */
  embeddingDims: number;
  /** Field name for embeddings (default: "embedding") */
  embeddingField?: string;
  /** Similarity metric (default: "cosine") */
  similarity?: SimilarityMetric;

  // Content settings
  /** Field name for text content (default: "content") */
  contentField?: string;
  /** Field name for metadata (default: "metadata") */
  metadataField?: string;

  // Connection options
  /** Maximum retry attempts (default: 3) */
  maxRetries?: number;
  /** Request timeout in milliseconds (default: 30000) */
  requestTimeout?: number;
  /** Enable request compression (default: false) */
  compression?: boolean;
  /** TLS/SSL configuration */
  tls?: {
    rejectUnauthorized?: boolean;
    ca?: string;
    cert?: string;
    key?: string;
  };

  // Embedding provider
  /** Optional embedding provider for automatic embedding */
  embedder?: EmbeddingProvider;
}

/**
 * Default configuration values
 */
export const DEFAULT_CONFIG = {
  embeddingField: 'embedding',
  contentField: 'content',
  metadataField: 'metadata',
  similarity: 'cosine' as SimilarityMetric,
  maxRetries: 3,
  requestTimeout: 30000,
  compression: false,
} as const;

// ============================================================================
// Document Types
// ============================================================================

/**
 * Document to be indexed
 */
export interface Document {
  /** Document ID (auto-generated if not provided) */
  id?: string;
  /** Text content */
  content: string;
  /** Pre-computed embedding vector (optional if embedder is configured) */
  embedding?: number[];
  /** Arbitrary metadata */
  metadata?: Record<string, unknown>;
}

/**
 * Document that has been indexed
 */
export interface IndexedDocument extends Required<Omit<Document, 'metadata'>> {
  /** Document ID */
  id: string;
  /** Text content */
  content: string;
  /** Embedding vector */
  embedding: number[];
  /** Metadata (optional) */
  metadata?: Record<string, unknown>;
  /** Timestamp when indexed */
  indexedAt: Date;
}

/**
 * Search result from vector or hybrid search
 */
export interface SearchResult<T = unknown> {
  /** Document ID */
  id: string;
  /** Relevance score */
  score: number;
  /** Text content */
  content: string;
  /** Document metadata */
  metadata?: Record<string, T>;
  /** Embedding vector (if requested) */
  embedding?: number[];
  /** Highlighted text snippets */
  highlights?: string[];
}

// ============================================================================
// Index Types
// ============================================================================

/**
 * HNSW algorithm parameters for kNN
 */
export interface HnswParams {
  /** Number of bi-directional links for HNSW (default: 16) */
  m?: number;
  /** Size of dynamic candidate list for construction (default: 100) */
  efConstruction?: number;
}

/**
 * Index settings for vector store
 */
export interface IndexSettings {
  /** Number of primary shards */
  numberOfShards?: number;
  /** Number of replica shards */
  numberOfReplicas?: number;
  /** Index refresh interval */
  refreshInterval?: string;
  /** Maximum result window size */
  maxResultWindow?: number;
  /** kNN algorithm parameters */
  knn?: {
    algoParam?: HnswParams;
  };
  /** Custom analyzers */
  analyzers?: Record<string, AnalyzerConfig>;
}

/**
 * Analyzer configuration
 */
export interface AnalyzerConfig {
  type?: string;
  tokenizer?: string;
  filter?: string[];
  charFilter?: string[];
}

/**
 * Index statistics
 */
export interface IndexStats {
  /** Index name */
  indexName: string;
  /** Total document count */
  documentCount: number;
  /** Index size in bytes */
  sizeInBytes: number;
  /** Number of primary shards */
  primaryShards: number;
  /** Number of replica shards */
  replicaShards: number;
  /** Index health status */
  health: 'green' | 'yellow' | 'red';
}

// ============================================================================
// Search Types
// ============================================================================

/**
 * Options for vector retrieval
 */
export interface RetrieveOptions {
  /** Number of results to return (default: 10) */
  k?: number;
  /** Number of candidates for kNN (default: k * 10) */
  numCandidates?: number;
  /** Minimum score threshold */
  minScore?: number;
  /** Metadata filter */
  filter?: Record<string, unknown>;
  /** Include embedding vectors in results */
  includeEmbedding?: boolean;
  /** Include text highlights in results */
  includeHighlights?: boolean;
}

/**
 * Default retrieval options
 */
export const DEFAULT_RETRIEVE_OPTIONS: Required<Pick<RetrieveOptions, 'k' | 'includeEmbedding' | 'includeHighlights'>> = {
  k: 10,
  includeEmbedding: false,
  includeHighlights: false,
};

/**
 * Options for hybrid search (vector + text)
 */
export interface HybridSearchOptions extends RetrieveOptions {
  /** Weight for vector score (0-1, default: 0.5) */
  vectorWeight?: number;
  /** Weight for text score (0-1, default: 0.5) */
  textWeight?: number;
  /** Fields to search for text query */
  textFields?: string[];
  /** Field-specific boost values */
  textBoost?: Record<string, number>;
  /** Fuzziness for text matching */
  fuzziness?: string | number;
  /** Operator for text matching ('and' or 'or') */
  operator?: 'and' | 'or';
}

/**
 * Default hybrid search options
 */
export const DEFAULT_HYBRID_OPTIONS: Required<Pick<HybridSearchOptions, 'vectorWeight' | 'textWeight' | 'operator'>> = {
  vectorWeight: 0.5,
  textWeight: 0.5,
  operator: 'or',
};

/**
 * Raw Elasticsearch search query
 */
export interface SearchQuery {
  /** Query DSL */
  query?: Record<string, unknown>;
  /** kNN configuration */
  knn?: KnnQuery;
  /** Number of results */
  size?: number;
  /** Starting offset */
  from?: number;
  /** Fields to return */
  _source?: boolean | string[] | { includes?: string[]; excludes?: string[] };
  /** Highlighting configuration */
  highlight?: HighlightConfig;
  /** Sort configuration */
  sort?: SortConfig[];
  /** Aggregations */
  aggs?: Record<string, unknown>;
}

/**
 * kNN query configuration
 */
export interface KnnQuery {
  /** Vector field name */
  field: string;
  /** Query vector */
  queryVector: number[];
  /** Number of results */
  k: number;
  /** Number of candidates */
  numCandidates?: number;
  /** Score boost */
  boost?: number;
  /** Pre-filter query */
  filter?: Record<string, unknown>;
}

/**
 * Highlight configuration
 */
export interface HighlightConfig {
  fields: Record<string, {
    type?: string;
    fragmentSize?: number;
    numberOfFragments?: number;
    preTags?: string[];
    postTags?: string[];
  }>;
  preTags?: string[];
  postTags?: string[];
}

/**
 * Sort configuration
 */
export type SortConfig = string | Record<string, 'asc' | 'desc' | { order: 'asc' | 'desc'; mode?: string }>;

/**
 * Elasticsearch search response
 */
export interface SearchResponse<T = unknown> {
  /** Total hits information */
  total: {
    value: number;
    relation: 'eq' | 'gte';
  };
  /** Maximum score */
  maxScore: number | null;
  /** Search hits */
  hits: SearchHit<T>[];
  /** Search duration in ms */
  took: number;
}

/**
 * Individual search hit
 */
export interface SearchHit<T = unknown> {
  /** Document ID */
  id: string;
  /** Relevance score */
  score: number | null;
  /** Document source */
  source: T;
  /** Highlighted fields */
  highlight?: Record<string, string[]>;
}

// ============================================================================
// Bulk Operation Types
// ============================================================================

/**
 * Result of bulk operation
 */
export interface BulkResult {
  /** Number of successful operations */
  successCount: number;
  /** Number of failed operations */
  failedCount: number;
  /** Individual item errors */
  errors: BulkItemError[];
  /** Duration in milliseconds */
  took: number;
  /** IDs of successfully indexed documents */
  indexedIds: string[];
}

/**
 * Individual bulk item error
 */
export interface BulkItemError {
  /** Document ID */
  id: string;
  /** Error type */
  type: string;
  /** Error reason */
  reason: string;
  /** HTTP status code */
  status: number;
}

// ============================================================================
// Grounding Module Types
// ============================================================================

/**
 * Configuration for grounding module
 */
export interface GroundingConfig {
  /** Number of documents to retrieve (default: 5) */
  topK?: number;
  /** Minimum relevance score (default: 0.0) */
  minRelevanceScore?: number;
  /** Include metadata in context */
  includeMetadata?: boolean;
  /** Custom context template */
  contextTemplate?: string;
  /** Embedding provider for query embedding */
  embedder: EmbeddingProvider;
  /** Use hybrid search */
  useHybridSearch?: boolean;
  /** Hybrid search options */
  hybridOptions?: Omit<HybridSearchOptions, 'k'>;
}

/**
 * Default grounding configuration
 */
export const DEFAULT_GROUNDING_CONFIG = {
  topK: 5,
  minRelevanceScore: 0.0,
  includeMetadata: false,
  useHybridSearch: false,
} as const;

/**
 * Options for grounding retrieval
 */
export interface GroundingOptions {
  /** Override number of documents */
  topK?: number;
  /** Override minimum score */
  minScore?: number;
  /** Metadata filter */
  filter?: Record<string, unknown>;
}

/**
 * Result of grounding retrieval
 */
export interface GroundingResult {
  /** Formatted context for LLM */
  context: string;
  /** Source documents */
  sources: GroundingSource[];
  /** Original query */
  query: string;
}

/**
 * Individual grounding source
 */
export interface GroundingSource {
  /** Document ID */
  id: string;
  /** Document content */
  content: string;
  /** Relevance score */
  score: number;
  /** Document metadata */
  metadata?: Record<string, unknown>;
}

// ============================================================================
// Ingest Pipeline Types
// ============================================================================

/**
 * Ingest pipeline configuration
 */
export interface IngestPipelineConfig {
  /** Pipeline name */
  name: string;
  /** Pipeline description */
  description?: string;
  /** Processors */
  processors: IngestProcessor[];
}

/**
 * Ingest processor configuration
 */
export interface IngestProcessor {
  /** Processor type */
  type: string;
  /** Processor configuration */
  config: Record<string, unknown>;
}

/**
 * Inference processor for embedding generation
 */
export interface InferenceProcessor extends IngestProcessor {
  type: 'inference';
  config: {
    /** Model ID for inference */
    modelId: string;
    /** Target field for output */
    targetField: string;
    /** Field mapping */
    fieldMap: Record<string, string>;
    /** Inference configuration */
    inferenceConfig?: Record<string, unknown>;
  };
}

// ============================================================================
// Type Guards
// ============================================================================

/**
 * Check if value is a valid Document
 */
export function isDocument(value: unknown): value is Document {
  if (typeof value !== 'object' || value === null) {
    return false;
  }
  const doc = value as Record<string, unknown>;
  return typeof doc.content === 'string';
}

/**
 * Check if value is an IndexedDocument
 */
export function isIndexedDocument(value: unknown): value is IndexedDocument {
  if (!isDocument(value)) {
    return false;
  }
  const doc = value as Record<string, unknown>;
  return (
    typeof doc.id === 'string' &&
    Array.isArray(doc.embedding) &&
    doc.indexedAt instanceof Date
  );
}

/**
 * Check if value is a valid embedding vector
 */
export function isEmbeddingVector(value: unknown, dims?: number): value is number[] {
  if (!Array.isArray(value)) {
    return false;
  }
  if (!value.every((v) => typeof v === 'number' && !isNaN(v))) {
    return false;
  }
  if (dims !== undefined && value.length !== dims) {
    return false;
  }
  return true;
}

/**
 * Check if value is a valid similarity metric
 */
export function isSimilarityMetric(value: unknown): value is SimilarityMetric {
  return value === 'cosine' || value === 'dot_product' || value === 'l2_norm';
}