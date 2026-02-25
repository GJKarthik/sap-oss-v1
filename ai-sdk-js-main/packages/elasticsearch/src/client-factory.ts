/**
 * @sap-ai-sdk/elasticsearch - Client Factory
 *
 * Factory for creating and managing Elasticsearch client connections.
 */

import { Client, type ClientOptions } from '@elastic/elasticsearch';
import type {
  ElasticsearchConfig,
  SimilarityMetric,
  IndexSettings,
} from './types.js';
import {
  ElasticsearchConnectionError,
  ElasticsearchConfigError,
  wrapError,
} from './errors.js';
import { validateConfig } from './validation.js';

// ============================================================================
// Client Factory
// ============================================================================

/**
 * Create an Elasticsearch client from configuration
 */
export function createElasticsearchClient(config: ElasticsearchConfig): Client {
  validateConfig(config);

  const clientOptions = buildClientOptions(config);

  try {
    return new Client(clientOptions);
  } catch (error) {
    throw new ElasticsearchConfigError(
      `Failed to create Elasticsearch client: ${error instanceof Error ? error.message : String(error)}`
    );
  }
}

/**
 * Build client options from configuration
 */
function buildClientOptions(config: ElasticsearchConfig): ClientOptions {
  const options: ClientOptions = {};

  // Node configuration
  if (config.node) {
    options.node = config.node;
  }

  // Cloud configuration
  if (config.cloud) {
    options.cloud = {
      id: config.cloud.id,
    };
  }

  // Authentication
  if (config.auth) {
    if (config.auth.apiKey) {
      options.auth = {
        apiKey: config.auth.apiKey,
      };
    } else if (config.auth.username && config.auth.password) {
      options.auth = {
        username: config.auth.username,
        password: config.auth.password,
      };
    } else if (config.auth.bearer) {
      options.auth = {
        bearer: config.auth.bearer,
      };
    }
  }

  // Connection options
  if (config.maxRetries !== undefined) {
    options.maxRetries = config.maxRetries;
  }

  if (config.requestTimeout !== undefined) {
    options.requestTimeout = config.requestTimeout;
  }

  if (config.compression !== undefined) {
    options.compression = config.compression;
  }

  // TLS configuration
  if (config.tls) {
    options.tls = {
      rejectUnauthorized: config.tls.rejectUnauthorized,
      ca: config.tls.ca,
      cert: config.tls.cert,
      key: config.tls.key,
    };
  }

  return options;
}

// ============================================================================
// Index Mapping Builder
// ============================================================================

/**
 * Build index mapping for vector store
 */
export function buildIndexMapping(config: {
  embeddingDims: number;
  embeddingField?: string;
  contentField?: string;
  metadataField?: string;
  similarity?: SimilarityMetric;
  settings?: IndexSettings;
}): Record<string, unknown> {
  const embeddingField = config.embeddingField ?? 'embedding';
  const contentField = config.contentField ?? 'content';
  const metadataField = config.metadataField ?? 'metadata';
  const similarity = config.similarity ?? 'cosine';

  const mappings: Record<string, unknown> = {
    properties: {
      [contentField]: {
        type: 'text',
        analyzer: 'standard',
        fields: {
          keyword: {
            type: 'keyword',
            ignore_above: 256,
          },
        },
      },
      [embeddingField]: {
        type: 'dense_vector',
        dims: config.embeddingDims,
        index: true,
        similarity: similarity,
      },
      [metadataField]: {
        type: 'object',
        dynamic: true,
      },
      indexed_at: {
        type: 'date',
      },
    },
  };

  const settings: Record<string, unknown> = {
    number_of_shards: config.settings?.numberOfShards ?? 1,
    number_of_replicas: config.settings?.numberOfReplicas ?? 1,
  };

  if (config.settings?.refreshInterval) {
    settings.refresh_interval = config.settings.refreshInterval;
  }

  if (config.settings?.maxResultWindow) {
    settings.max_result_window = config.settings.maxResultWindow;
  }

  // HNSW algorithm parameters
  if (config.settings?.knn?.algoParam) {
    const knnParams: Record<string, unknown> = {};
    if (config.settings.knn.algoParam.m !== undefined) {
      knnParams.m = config.settings.knn.algoParam.m;
    }
    if (config.settings.knn.algoParam.efConstruction !== undefined) {
      knnParams.ef_construction = config.settings.knn.algoParam.efConstruction;
    }
    if (Object.keys(knnParams).length > 0) {
      (mappings.properties as Record<string, unknown>)[embeddingField] = {
        ...((mappings.properties as Record<string, unknown>)[embeddingField] as Record<string, unknown>),
        index_options: {
          type: 'hnsw',
          ...knnParams,
        },
      };
    }
  }

  // Custom analyzers
  if (config.settings?.analyzers) {
    const analysis: Record<string, unknown> = { analyzer: {} };
    for (const [name, analyzerConfig] of Object.entries(config.settings.analyzers)) {
      (analysis.analyzer as Record<string, unknown>)[name] = {
        type: analyzerConfig.type ?? 'custom',
        tokenizer: analyzerConfig.tokenizer,
        filter: analyzerConfig.filter,
        char_filter: analyzerConfig.charFilter,
      };
    }
    settings.analysis = analysis;
  }

  return {
    mappings,
    settings,
  };
}

// ============================================================================
// Connection Management
// ============================================================================

/**
 * Test connection to Elasticsearch
 */
export async function testConnection(client: Client): Promise<{
  connected: boolean;
  version?: string;
  clusterName?: string;
  error?: string;
}> {
  try {
    const info = await client.info();
    return {
      connected: true,
      version: info.version?.number,
      clusterName: info.cluster_name,
    };
  } catch (error) {
    const wrapped = wrapError(error, 'Connection test failed');
    return {
      connected: false,
      error: wrapped.message,
    };
  }
}

/**
 * Ping Elasticsearch cluster
 */
export async function pingCluster(client: Client): Promise<boolean> {
  try {
    await client.ping();
    return true;
  } catch {
    return false;
  }
}

/**
 * Get cluster health
 */
export async function getClusterHealth(client: Client): Promise<{
  status: 'green' | 'yellow' | 'red';
  numberOfNodes: number;
  numberOfDataNodes: number;
  activePrimaryShards: number;
  activeShards: number;
  unassignedShards: number;
}> {
  try {
    const health = await client.cluster.health();
    return {
      status: health.status as 'green' | 'yellow' | 'red',
      numberOfNodes: health.number_of_nodes,
      numberOfDataNodes: health.number_of_data_nodes,
      activePrimaryShards: health.active_primary_shards,
      activeShards: health.active_shards,
      unassignedShards: health.unassigned_shards,
    };
  } catch (error) {
    throw new ElasticsearchConnectionError(
      'Failed to get cluster health',
      { cause: error instanceof Error ? error : undefined }
    );
  }
}

// ============================================================================
// Configuration Builder
// ============================================================================

/**
 * Builder pattern for ElasticsearchConfig
 */
export class ElasticsearchConfigBuilder {
  private config: Partial<ElasticsearchConfig> = {};

  /**
   * Set node URL(s)
   */
  node(url: string | string[]): this {
    this.config.node = url;
    return this;
  }

  /**
   * Set Elastic Cloud configuration
   */
  cloud(id: string): this {
    this.config.cloud = { id };
    return this;
  }

  /**
   * Set API key authentication
   */
  apiKey(key: string | { id: string; api_key: string }): this {
    this.config.auth = { apiKey: key };
    return this;
  }

  /**
   * Set basic authentication
   */
  basicAuth(username: string, password: string): this {
    this.config.auth = { username, password };
    return this;
  }

  /**
   * Set bearer token authentication
   */
  bearerToken(token: string): this {
    this.config.auth = { bearer: token };
    return this;
  }

  /**
   * Set target index name
   */
  index(name: string): this {
    this.config.indexName = name;
    return this;
  }

  /**
   * Set embedding dimensions
   */
  embeddingDimensions(dims: number): this {
    this.config.embeddingDims = dims;
    return this;
  }

  /**
   * Set similarity metric
   */
  similarity(metric: SimilarityMetric): this {
    this.config.similarity = metric;
    return this;
  }

  /**
   * Set embedding field name
   */
  embeddingField(name: string): this {
    this.config.embeddingField = name;
    return this;
  }

  /**
   * Set content field name
   */
  contentField(name: string): this {
    this.config.contentField = name;
    return this;
  }

  /**
   * Set metadata field name
   */
  metadataField(name: string): this {
    this.config.metadataField = name;
    return this;
  }

  /**
   * Set maximum retries
   */
  maxRetries(count: number): this {
    this.config.maxRetries = count;
    return this;
  }

  /**
   * Set request timeout
   */
  timeout(ms: number): this {
    this.config.requestTimeout = ms;
    return this;
  }

  /**
   * Enable compression
   */
  compression(enabled: boolean = true): this {
    this.config.compression = enabled;
    return this;
  }

  /**
   * Set TLS configuration
   */
  tls(options: {
    rejectUnauthorized?: boolean;
    ca?: string;
    cert?: string;
    key?: string;
  }): this {
    this.config.tls = options;
    return this;
  }

  /**
   * Build the configuration
   */
  build(): ElasticsearchConfig {
    // Validate required fields
    if (!this.config.node && !this.config.cloud) {
      throw new ElasticsearchConfigError('Either node or cloud configuration is required');
    }

    if (!this.config.indexName) {
      throw new ElasticsearchConfigError('Index name is required');
    }

    if (!this.config.embeddingDims) {
      throw new ElasticsearchConfigError('Embedding dimensions are required');
    }

    return this.config as ElasticsearchConfig;
  }

  /**
   * Create a copy of the current configuration
   */
  clone(): ElasticsearchConfigBuilder {
    const builder = new ElasticsearchConfigBuilder();
    builder.config = { ...this.config };
    return builder;
  }
}

/**
 * Create a new configuration builder
 */
export function configBuilder(): ElasticsearchConfigBuilder {
  return new ElasticsearchConfigBuilder();
}

// ============================================================================
// Environment Configuration
// ============================================================================

/**
 * Create configuration from environment variables
 */
export function configFromEnv(prefix: string = 'ES'): ElasticsearchConfig {
  const env = process.env;

  const node = env[`${prefix}_NODE`] ?? env[`${prefix}_URL`];
  const cloudId = env[`${prefix}_CLOUD_ID`];
  const apiKey = env[`${prefix}_API_KEY`];
  const username = env[`${prefix}_USERNAME`];
  const password = env[`${prefix}_PASSWORD`];
  const indexName = env[`${prefix}_INDEX`] ?? env[`${prefix}_INDEX_NAME`];
  const embeddingDims = env[`${prefix}_EMBEDDING_DIMS`];

  if (!node && !cloudId) {
    throw new ElasticsearchConfigError(
      `Missing ${prefix}_NODE or ${prefix}_CLOUD_ID environment variable`
    );
  }

  if (!indexName) {
    throw new ElasticsearchConfigError(
      `Missing ${prefix}_INDEX environment variable`
    );
  }

  if (!embeddingDims) {
    throw new ElasticsearchConfigError(
      `Missing ${prefix}_EMBEDDING_DIMS environment variable`
    );
  }

  const config: ElasticsearchConfig = {
    node: node ?? '',
    indexName,
    embeddingDims: parseInt(embeddingDims, 10),
  };

  if (cloudId) {
    config.cloud = { id: cloudId };
  }

  if (apiKey) {
    config.auth = { apiKey };
  } else if (username && password) {
    config.auth = { username, password };
  }

  // Optional configuration
  const similarity = env[`${prefix}_SIMILARITY`];
  if (similarity) {
    config.similarity = similarity as SimilarityMetric;
  }

  const maxRetries = env[`${prefix}_MAX_RETRIES`];
  if (maxRetries) {
    config.maxRetries = parseInt(maxRetries, 10);
  }

  const timeout = env[`${prefix}_TIMEOUT`];
  if (timeout) {
    config.requestTimeout = parseInt(timeout, 10);
  }

  return config;
}

// ============================================================================
// Presets
// ============================================================================

/**
 * Common configuration presets
 */
export const ConfigPresets = {
  /**
   * Local development preset
   */
  local(indexName: string, embeddingDims: number = 1536): ElasticsearchConfig {
    return {
      node: 'http://localhost:9200',
      indexName,
      embeddingDims,
      maxRetries: 3,
      requestTimeout: 30000,
    };
  },

  /**
   * Elastic Cloud preset
   */
  elasticCloud(
    cloudId: string,
    apiKey: string,
    indexName: string,
    embeddingDims: number = 1536
  ): ElasticsearchConfig {
    return {
      node: '', // Not used with cloud
      cloud: { id: cloudId },
      auth: { apiKey },
      indexName,
      embeddingDims,
      compression: true,
      maxRetries: 3,
      requestTimeout: 30000,
    };
  },

  /**
   * OpenAI embeddings preset (1536 dimensions)
   */
  openAI(
    node: string,
    indexName: string,
    auth?: { apiKey?: string; username?: string; password?: string }
  ): ElasticsearchConfig {
    return {
      node,
      indexName,
      embeddingDims: 1536,
      similarity: 'cosine',
      auth,
    };
  },

  /**
   * Azure OpenAI embeddings preset (1536 dimensions)
   */
  azureOpenAI(
    node: string,
    indexName: string,
    auth?: { apiKey?: string; username?: string; password?: string }
  ): ElasticsearchConfig {
    return {
      node,
      indexName,
      embeddingDims: 1536,
      similarity: 'cosine',
      auth,
    };
  },

  /**
   * Cohere embeddings preset (1024 dimensions for embed-english-v3.0)
   */
  cohere(
    node: string,
    indexName: string,
    auth?: { apiKey?: string; username?: string; password?: string }
  ): ElasticsearchConfig {
    return {
      node,
      indexName,
      embeddingDims: 1024,
      similarity: 'cosine',
      auth,
    };
  },

  /**
   * High-performance preset for production
   */
  production(
    node: string | string[],
    indexName: string,
    embeddingDims: number,
    apiKey: string
  ): ElasticsearchConfig {
    return {
      node,
      indexName,
      embeddingDims,
      auth: { apiKey },
      compression: true,
      maxRetries: 5,
      requestTimeout: 60000,
    };
  },
};