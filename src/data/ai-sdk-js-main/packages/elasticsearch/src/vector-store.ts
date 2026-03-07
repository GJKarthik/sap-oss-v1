// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * @sap-ai-sdk/elasticsearch - Vector Store
 *
 * Core ElasticsearchVectorStore implementation for vector storage and retrieval.
 */

import { Client } from '@elastic/elasticsearch';
import type {
  ElasticsearchConfig,
  Document,
  IndexedDocument,
  SearchResult,
  RetrieveOptions,
  IndexStats,
} from './types.js';

/**
 * Options for upsert operations
 */
export interface UpsertOptions {
  /** Batch size for bulk operations (default: 500) */
  batchSize?: number;
  /** Refresh index after operation (default: false) */
  refresh?: boolean;
  /** Progress callback */
  onProgress?: (progress: UpsertProgress) => void;
}

/**
 * Progress info for upsert operations
 */
export interface UpsertProgress {
  /** Documents processed so far */
  processed: number;
  /** Total documents */
  total: number;
  /** Successfully indexed documents */
  successCount: number;
  /** Failed documents */
  failedCount: number;
  /** Percentage complete (0-100) */
  percentComplete: number;
}

/**
 * Result of a bulk operation
 */
export interface BulkOperationResult {
  /** Total documents in operation */
  total: number;
  /** Successfully processed documents */
  successCount: number;
  /** Failed documents */
  failedCount: number;
  /** Error details for failed documents */
  errors: BulkItemErrorInfo[];
  /** Duration in milliseconds */
  duration: number;
}

/**
 * Error info for a single bulk item
 */
export interface BulkItemErrorInfo {
  /** Index in the batch */
  index: number;
  /** Document ID */
  id: string;
  /** Error details */
  error: {
    type: string;
    reason: string;
  };
  /** HTTP status code */
  status: number;
}
import {
  ElasticsearchConnectionError,
  ElasticsearchIndexError,
  ElasticsearchIndexNotFoundError,
  ElasticsearchIndexExistsError,
  ElasticsearchDocumentNotFoundError,
  ElasticsearchBulkError,
  wrapError,
} from './errors.js';
import {
  validateConfig,
  validateDocument,
  validateDocuments,
  validateEmbedding,
  validateRetrieveOptions,
  generateDocumentId,
} from './validation.js';
import {
  createElasticsearchClient,
  buildIndexMapping,
  testConnection,
} from './client-factory.js';

// ============================================================================
// ElasticsearchVectorStore Class
// ============================================================================

/**
 * Elasticsearch vector store for document storage and retrieval.
 *
 * @example
 * ```typescript
 * const vectorStore = new ElasticsearchVectorStore({
 *   node: 'https://localhost:9200',
 *   indexName: 'documents',
 *   embeddingDims: 1536,
 * });
 *
 * await vectorStore.initialize();
 *
 * await vectorStore.upsertDocuments([
 *   { content: 'Hello world', embedding: [...] },
 * ]);
 *
 * const results = await vectorStore.retrieve([0.1, 0.2, ...], { k: 5 });
 *
 * await vectorStore.close();
 * ```
 */
export class ElasticsearchVectorStore {
  private readonly config: Required<
    Pick<ElasticsearchConfig, 'indexName' | 'embeddingDims' | 'similarity'>
  > &
    ElasticsearchConfig;
  private readonly client: Client;
  private initialized: boolean = false;

  // Field names
  private readonly embeddingField: string;
  private readonly contentField: string;
  private readonly metadataField: string;

  /**
   * Create a new ElasticsearchVectorStore
   */
  constructor(config: ElasticsearchConfig) {
    validateConfig(config);

    this.config = {
      ...config,
      similarity: config.similarity ?? 'cosine',
    };

    this.client = createElasticsearchClient(config);

    // Set field names
    this.embeddingField = config.embeddingField ?? 'embedding';
    this.contentField = config.contentField ?? 'content';
    this.metadataField = config.metadataField ?? 'metadata';
  }

  // ============================================================================
  // Lifecycle Methods
  // ============================================================================

  /**
   * Initialize the vector store, creating the index if needed
   */
  async initialize(options: { createIndex?: boolean } = {}): Promise<void> {
    const { createIndex = true } = options;

    // Test connection
    const connectionResult = await testConnection(this.client);
    if (!connectionResult.connected) {
      throw new ElasticsearchConnectionError(
        `Failed to connect to Elasticsearch: ${connectionResult.error}`
      );
    }

    // Create index if needed
    if (createIndex) {
      const exists = await this.indexExists();
      if (!exists) {
        await this.createIndex();
      }
    }

    this.initialized = true;
  }

  /**
   * Close the vector store and release resources
   */
  async close(): Promise<void> {
    await this.client.close();
    this.initialized = false;
  }

  /**
   * Check if the vector store is initialized
   */
  isInitialized(): boolean {
    return this.initialized;
  }

  /**
   * Get the underlying Elasticsearch client
   */
  getClient(): Client {
    return this.client;
  }

  /**
   * Get the configuration
   */
  getConfig(): ElasticsearchConfig {
    return this.config;
  }

  // ============================================================================
  // Index Management
  // ============================================================================

  /**
   * Check if the index exists
   */
  async indexExists(): Promise<boolean> {
    try {
      return await this.client.indices.exists({
        index: this.config.indexName,
      });
    } catch (error) {
      throw wrapError(error, 'Failed to check index existence');
    }
  }

  /**
   * Create the index with vector mapping
   */
  async createIndex(options: {
    ifNotExists?: boolean;
  } = {}): Promise<void> {
    const { ifNotExists = false } = options;

    try {
      if (ifNotExists) {
        const exists = await this.indexExists();
        if (exists) {
          return;
        }
      }

      const mapping = buildIndexMapping({
        embeddingDims: this.config.embeddingDims,
        embeddingField: this.embeddingField,
        contentField: this.contentField,
        metadataField: this.metadataField,
        similarity: this.config.similarity,
        settings: this.config.indexSettings,
      });

      await this.client.indices.create({
        index: this.config.indexName,
        ...mapping,
      });
    } catch (error) {
      // Check if it's an index already exists error
      if (
        error instanceof Error &&
        error.message.includes('resource_already_exists_exception')
      ) {
        throw new ElasticsearchIndexExistsError(this.config.indexName);
      }
      throw new ElasticsearchIndexError(
        `Failed to create index ${this.config.indexName}`,
        this.config.indexName,
        { cause: error instanceof Error ? error : undefined }
      );
    }
  }

  /**
   * Delete the index
   */
  async deleteIndex(options: {
    ifExists?: boolean;
  } = {}): Promise<void> {
    const { ifExists = false } = options;

    try {
      if (ifExists) {
        const exists = await this.indexExists();
        if (!exists) {
          return;
        }
      }

      await this.client.indices.delete({
        index: this.config.indexName,
      });
    } catch (error) {
      // Check if it's an index not found error
      if (
        error instanceof Error &&
        error.message.includes('index_not_found_exception')
      ) {
        throw new ElasticsearchIndexNotFoundError(this.config.indexName);
      }
      throw new ElasticsearchIndexError(
        `Failed to delete index ${this.config.indexName}`,
        this.config.indexName,
        { cause: error instanceof Error ? error : undefined }
      );
    }
  }

  /**
   * Get index statistics
   */
  async getIndexStats(): Promise<IndexStats> {
    try {
      const exists = await this.indexExists();
      if (!exists) {
        throw new ElasticsearchIndexNotFoundError(this.config.indexName);
      }

      const stats = await this.client.indices.stats({
        index: this.config.indexName,
      });

      const indexStats = stats.indices?.[this.config.indexName];

      return {
        indexName: this.config.indexName,
        documentCount: indexStats?.primaries?.docs?.count ?? 0,
        sizeInBytes: indexStats?.primaries?.store?.size_in_bytes ?? 0,
        health: (indexStats as { health?: string })?.health ?? 'unknown',
      };
    } catch (error) {
      if (error instanceof ElasticsearchIndexNotFoundError) {
        throw error;
      }
      throw wrapError(error, 'Failed to get index stats');
    }
  }

  /**
   * Refresh the index to make recent changes searchable
   */
  async refresh(): Promise<void> {
    try {
      await this.client.indices.refresh({
        index: this.config.indexName,
      });
    } catch (error) {
      throw wrapError(error, 'Failed to refresh index');
    }
  }

  // ============================================================================
  // Document Operations
  // ============================================================================

  /**
   * Index a single document
   */
  async indexDocument(doc: Document): Promise<IndexedDocument> {
    validateDocument(doc, this.config.embeddingDims, true);

    const id = doc.id ?? generateDocumentId();

    try {
      await this.client.index({
        index: this.config.indexName,
        id,
        document: {
          [this.contentField]: doc.content,
          [this.embeddingField]: doc.embedding,
          [this.metadataField]: doc.metadata ?? {},
          indexed_at: new Date().toISOString(),
        },
      });

      return {
        ...doc,
        id,
        indexedAt: new Date(),
      };
    } catch (error) {
      throw wrapError(error, 'Failed to index document');
    }
  }

  /**
   * Get a document by ID
   */
  async getDocument(id: string): Promise<IndexedDocument | null> {
    try {
      const response = await this.client.get({
        index: this.config.indexName,
        id,
      });

      if (!response.found) {
        return null;
      }

      const source = response._source as Record<string, unknown>;

      return {
        id: response._id,
        content: source[this.contentField] as string,
        embedding: source[this.embeddingField] as number[],
        metadata: source[this.metadataField] as Record<string, unknown>,
        indexedAt: source.indexed_at
          ? new Date(source.indexed_at as string)
          : undefined,
      };
    } catch (error) {
      // Check for document not found
      if (
        error instanceof Error &&
        (error.message.includes('not_found') ||
          error.message.includes('404'))
      ) {
        return null;
      }
      throw wrapError(error, 'Failed to get document');
    }
  }

  /**
   * Delete a document by ID
   */
  async deleteDocument(id: string): Promise<boolean> {
    try {
      const response = await this.client.delete({
        index: this.config.indexName,
        id,
      });

      return response.result === 'deleted';
    } catch (error) {
      // Check for document not found
      if (
        error instanceof Error &&
        (error.message.includes('not_found') ||
          error.message.includes('404'))
      ) {
        return false;
      }
      throw wrapError(error, 'Failed to delete document');
    }
  }

  /**
   * Check if a document exists
   */
  async documentExists(id: string): Promise<boolean> {
    try {
      return await this.client.exists({
        index: this.config.indexName,
        id,
      });
    } catch (error) {
      throw wrapError(error, 'Failed to check document existence');
    }
  }

  // ============================================================================
  // Bulk Operations
  // ============================================================================

  /**
   * Upsert multiple documents using bulk API
   *
   * @param docs - Documents to upsert
   * @param options - Bulk operation options
   * @returns Bulk operation result with success/failure counts
   */
  async upsertDocuments(
    docs: Document[],
    options: UpsertOptions = {}
  ): Promise<BulkOperationResult> {
    validateDocuments(docs, this.config.embeddingDims, true);

    const {
      batchSize = 500,
      refresh = false,
      onProgress,
    } = options;

    const startTime = Date.now();
    const totalDocs = docs.length;
    let successCount = 0;
    let failedCount = 0;
    const errors: BulkItemErrorInfo[] = [];

    // Process in batches
    for (let i = 0; i < totalDocs; i += batchSize) {
      const batch = docs.slice(i, i + batchSize);
      const batchResult = await this.processBatch(batch);

      successCount += batchResult.successCount;
      failedCount += batchResult.failedCount;
      errors.push(...batchResult.errors);

      // Report progress
      if (onProgress) {
        const processed = Math.min(i + batchSize, totalDocs);
        onProgress({
          processed,
          total: totalDocs,
          successCount,
          failedCount,
          percentComplete: Math.round((processed / totalDocs) * 100),
        });
      }
    }

    // Refresh index if requested
    if (refresh) {
      await this.refresh();
    }

    const duration = Date.now() - startTime;

    return {
      total: totalDocs,
      successCount,
      failedCount,
      errors,
      duration,
    };
  }

  /**
   * Process a batch of documents
   */
  private async processBatch(docs: Document[]): Promise<{
    successCount: number;
    failedCount: number;
    errors: BulkItemErrorInfo[];
  }> {
    const operations: Array<Record<string, unknown>> = [];
    const now = new Date().toISOString();

    // Build bulk operations
    for (const doc of docs) {
      const id = doc.id ?? generateDocumentId();

      // Index operation
      operations.push({
        index: {
          _index: this.config.indexName,
          _id: id,
        },
      });

      // Document
      operations.push({
        [this.contentField]: doc.content,
        [this.embeddingField]: doc.embedding,
        [this.metadataField]: doc.metadata ?? {},
        indexed_at: now,
      });
    }

    try {
      const response = await this.client.bulk({
        operations,
        refresh: false, // We handle refresh separately
      });

      let successCount = 0;
      let failedCount = 0;
      const errors: BulkItemErrorInfo[] = [];

      // Process response items
      if (response.items) {
        for (let i = 0; i < response.items.length; i++) {
          const item = response.items[i];
          const indexResult = item.index;

          if (indexResult?.error) {
            failedCount++;
            errors.push({
              index: i,
              id: indexResult._id ?? docs[i]?.id ?? 'unknown',
              error: {
                type: indexResult.error.type ?? 'unknown',
                reason: indexResult.error.reason ?? 'Unknown error',
              },
              status: indexResult.status ?? 500,
            });
          } else {
            successCount++;
          }
        }
      }

      return { successCount, failedCount, errors };
    } catch (error) {
      // If the entire bulk request failed, mark all as failed
      return {
        successCount: 0,
        failedCount: docs.length,
        errors: docs.map((doc, index) => ({
          index,
          id: doc.id ?? 'unknown',
          error: {
            type: 'bulk_request_error',
            reason: error instanceof Error ? error.message : 'Unknown error',
          },
          status: 500,
        })),
      };
    }
  }

  /**
   * Delete multiple documents by IDs
   *
   * @param ids - Document IDs to delete
   * @param options - Bulk operation options
   * @returns Bulk operation result
   */
  async deleteDocuments(
    ids: string[],
    options: { refresh?: boolean } = {}
  ): Promise<BulkOperationResult> {
    if (ids.length === 0) {
      return {
        total: 0,
        successCount: 0,
        failedCount: 0,
        errors: [],
        duration: 0,
      };
    }

    const startTime = Date.now();
    const operations: Array<Record<string, unknown>> = [];

    // Build bulk delete operations
    for (const id of ids) {
      operations.push({
        delete: {
          _index: this.config.indexName,
          _id: id,
        },
      });
    }

    try {
      const response = await this.client.bulk({
        operations,
        refresh: false,
      });

      let successCount = 0;
      let failedCount = 0;
      const errors: BulkItemErrorInfo[] = [];

      // Process response items
      if (response.items) {
        for (let i = 0; i < response.items.length; i++) {
          const item = response.items[i];
          const deleteResult = item.delete;

          if (deleteResult?.error) {
            failedCount++;
            errors.push({
              index: i,
              id: ids[i],
              error: {
                type: deleteResult.error.type ?? 'unknown',
                reason: deleteResult.error.reason ?? 'Unknown error',
              },
              status: deleteResult.status ?? 500,
            });
          } else if (deleteResult?.result === 'not_found') {
            failedCount++;
            errors.push({
              index: i,
              id: ids[i],
              error: {
                type: 'not_found',
                reason: 'Document not found',
              },
              status: 404,
            });
          } else {
            successCount++;
          }
        }
      }

      // Refresh if requested
      if (options.refresh) {
        await this.refresh();
      }

      return {
        total: ids.length,
        successCount,
        failedCount,
        errors,
        duration: Date.now() - startTime,
      };
    } catch (error) {
      return {
        total: ids.length,
        successCount: 0,
        failedCount: ids.length,
        errors: ids.map((id, index) => ({
          index,
          id,
          error: {
            type: 'bulk_request_error',
            reason: error instanceof Error ? error.message : 'Unknown error',
          },
          status: 500,
        })),
        duration: Date.now() - startTime,
      };
    }
  }

  /**
   * Update multiple documents' metadata
   *
   * @param updates - Array of {id, metadata} objects
   * @param options - Bulk operation options
   * @returns Bulk operation result
   */
  async updateDocumentsMetadata(
    updates: Array<{ id: string; metadata: Record<string, unknown> }>,
    options: { refresh?: boolean } = {}
  ): Promise<BulkOperationResult> {
    if (updates.length === 0) {
      return {
        total: 0,
        successCount: 0,
        failedCount: 0,
        errors: [],
        duration: 0,
      };
    }

    const startTime = Date.now();
    const operations: Array<Record<string, unknown>> = [];

    // Build bulk update operations
    for (const { id, metadata } of updates) {
      operations.push({
        update: {
          _index: this.config.indexName,
          _id: id,
        },
      });
      operations.push({
        doc: {
          [this.metadataField]: metadata,
        },
      });
    }

    try {
      const response = await this.client.bulk({
        operations,
        refresh: false,
      });

      let successCount = 0;
      let failedCount = 0;
      const errors: BulkItemErrorInfo[] = [];

      // Process response items
      if (response.items) {
        for (let i = 0; i < response.items.length; i++) {
          const item = response.items[i];
          const updateResult = item.update;

          if (updateResult?.error) {
            failedCount++;
            errors.push({
              index: i,
              id: updates[i].id,
              error: {
                type: updateResult.error.type ?? 'unknown',
                reason: updateResult.error.reason ?? 'Unknown error',
              },
              status: updateResult.status ?? 500,
            });
          } else {
            successCount++;
          }
        }
      }

      // Refresh if requested
      if (options.refresh) {
        await this.refresh();
      }

      return {
        total: updates.length,
        successCount,
        failedCount,
        errors,
        duration: Date.now() - startTime,
      };
    } catch (error) {
      return {
        total: updates.length,
        successCount: 0,
        failedCount: updates.length,
        errors: updates.map((update, index) => ({
          index,
          id: update.id,
          error: {
            type: 'bulk_request_error',
            reason: error instanceof Error ? error.message : 'Unknown error',
          },
          status: 500,
        })),
        duration: Date.now() - startTime,
      };
    }
  }

  /**
   * Delete all documents matching a query
   *
   * @param query - Elasticsearch query to match documents
   * @returns Number of deleted documents
   */
  async deleteByQuery(query: Record<string, unknown>): Promise<number> {
    try {
      const response = await this.client.deleteByQuery({
        index: this.config.indexName,
        query,
      });

      return response.deleted ?? 0;
    } catch (error) {
      throw wrapError(error, 'Failed to delete by query');
    }
  }

  /**
   * Get multiple documents by IDs
   */
  async getDocuments(ids: string[]): Promise<(IndexedDocument | null)[]> {
    if (ids.length === 0) {
      return [];
    }

    try {
      const response = await this.client.mget({
        index: this.config.indexName,
        ids,
      });

      return response.docs.map((doc) => {
        if (!('found' in doc) || !doc.found) {
          return null;
        }

        const source = doc._source as Record<string, unknown>;

        return {
          id: doc._id,
          content: source[this.contentField] as string,
          embedding: source[this.embeddingField] as number[],
          metadata: source[this.metadataField] as Record<string, unknown>,
          indexedAt: source.indexed_at
            ? new Date(source.indexed_at as string)
            : undefined,
        };
      });
    } catch (error) {
      throw wrapError(error, 'Failed to get documents');
    }
  }

  // ============================================================================
  // Basic Search
  // ============================================================================

  /**
   * Retrieve documents using kNN vector search
   */
  async retrieve(
    embedding: number[],
    options: RetrieveOptions = {}
  ): Promise<SearchResult[]> {
    validateEmbedding(embedding, this.config.embeddingDims);
    validateRetrieveOptions(options);

    const {
      k = 10,
      numCandidates = k * 2,
      minScore,
      filter,
      includeEmbedding = false,
    } = options;

    try {
      const searchRequest: Record<string, unknown> = {
        index: this.config.indexName,
        knn: {
          field: this.embeddingField,
          query_vector: embedding,
          k,
          num_candidates: numCandidates,
        },
        _source: {
          excludes: includeEmbedding ? [] : [this.embeddingField],
        },
      };

      // Add filter if provided
      if (filter) {
        (searchRequest.knn as Record<string, unknown>).filter = filter;
      }

      // Add min_score if provided
      if (minScore !== undefined) {
        searchRequest.min_score = minScore;
      }

      const response = await this.client.search(searchRequest);

      return this.transformSearchHits(response.hits.hits, includeEmbedding);
    } catch (error) {
      throw wrapError(error, 'Failed to retrieve documents');
    }
  }

  /**
   * Search by text query (BM25)
   */
  async searchByText(
    query: string,
    options: RetrieveOptions = {}
  ): Promise<SearchResult[]> {
    validateRetrieveOptions(options);

    const { k = 10, minScore, filter, includeEmbedding = false } = options;

    try {
      const searchRequest: Record<string, unknown> = {
        index: this.config.indexName,
        size: k,
        query: {
          bool: {
            must: [
              {
                match: {
                  [this.contentField]: query,
                },
              },
            ],
          },
        },
        _source: {
          excludes: includeEmbedding ? [] : [this.embeddingField],
        },
      };

      // Add filter if provided
      if (filter) {
        (
          (searchRequest.query as Record<string, unknown>)
            .bool as Record<string, unknown>
        ).filter = filter;
      }

      // Add min_score if provided
      if (minScore !== undefined) {
        searchRequest.min_score = minScore;
      }

      const response = await this.client.search(searchRequest);

      return this.transformSearchHits(response.hits.hits, includeEmbedding);
    } catch (error) {
      throw wrapError(error, 'Failed to search by text');
    }
  }

  // ============================================================================
  // Helper Methods
  // ============================================================================

  /**
   * Transform Elasticsearch search hits to SearchResult[]
   */
  private transformSearchHits(
    hits: Array<{
      _id?: string;
      _score?: number | null;
      _source?: unknown;
    }>,
    includeEmbedding: boolean
  ): SearchResult[] {
    return hits.map((hit) => {
      const source = hit._source as Record<string, unknown>;

      const result: SearchResult = {
        id: hit._id ?? '',
        score: hit._score ?? 0,
        content: source[this.contentField] as string,
        metadata: source[this.metadataField] as Record<string, unknown>,
      };

      if (includeEmbedding && source[this.embeddingField]) {
        result.embedding = source[this.embeddingField] as number[];
      }

      return result;
    });
  }

  /**
   * Ensure the vector store is initialized
   */
  private ensureInitialized(): void {
    if (!this.initialized) {
      throw new ElasticsearchConnectionError(
        'Vector store is not initialized. Call initialize() first.'
      );
    }
  }
}

// ============================================================================
// Factory Functions
// ============================================================================

/**
 * Create and initialize a vector store
 */
export async function createVectorStore(
  config: ElasticsearchConfig
): Promise<ElasticsearchVectorStore> {
  const store = new ElasticsearchVectorStore(config);
  await store.initialize();
  return store;
}

/**
 * Create a vector store without initializing
 */
export function createUninitializedVectorStore(
  config: ElasticsearchConfig
): ElasticsearchVectorStore {
  return new ElasticsearchVectorStore(config);
}