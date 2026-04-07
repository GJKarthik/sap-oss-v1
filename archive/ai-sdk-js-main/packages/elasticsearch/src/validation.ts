// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * @sap-ai-sdk/elasticsearch - Configuration Validation
 *
 * Utilities for validating configuration and inputs.
 */

import type {
  ElasticsearchConfig,
  Document,
  RetrieveOptions,
  HybridSearchOptions,
  IndexSettings,
  SimilarityMetric,
} from './types.js';
import {
  ElasticsearchConfigError,
  ElasticsearchValidationError,
  ElasticsearchEmbeddingError,
} from './errors.js';

// ============================================================================
// Configuration Validation
// ============================================================================

/**
 * Validate Elasticsearch configuration
 */
export function validateConfig(config: ElasticsearchConfig): void {
  // Required fields
  if (!config.node && !config.cloud) {
    throw new ElasticsearchConfigError(
      'Either "node" or "cloud" configuration is required',
      'node'
    );
  }

  if (!config.indexName) {
    throw new ElasticsearchConfigError(
      '"indexName" is required',
      'indexName'
    );
  }

  if (typeof config.embeddingDims !== 'number' || config.embeddingDims <= 0) {
    throw new ElasticsearchConfigError(
      '"embeddingDims" must be a positive number',
      'embeddingDims'
    );
  }

  // Node validation
  if (config.node) {
    const nodes = Array.isArray(config.node) ? config.node : [config.node];
    for (const node of nodes) {
      if (!isValidUrl(node)) {
        throw new ElasticsearchConfigError(
          `Invalid node URL: ${node}`,
          'node'
        );
      }
    }
  }

  // Cloud validation
  if (config.cloud && !config.cloud.id) {
    throw new ElasticsearchConfigError(
      'Cloud configuration requires "id"',
      'cloud.id'
    );
  }

  // Index name validation
  if (!isValidIndexName(config.indexName)) {
    throw new ElasticsearchConfigError(
      `Invalid index name: ${config.indexName}. Index names must be lowercase, cannot start with -, _, +, and cannot contain special characters.`,
      'indexName'
    );
  }

  // Similarity validation
  if (config.similarity && !isValidSimilarity(config.similarity)) {
    throw new ElasticsearchConfigError(
      `Invalid similarity metric: ${config.similarity}. Valid values are: cosine, dot_product, l2_norm`,
      'similarity'
    );
  }

  // Embedding dims validation
  if (config.embeddingDims > 4096) {
    console.warn(
      `Warning: embeddingDims (${config.embeddingDims}) is unusually high. Most embedding models use 1536 or fewer dimensions.`
    );
  }

  // Optional numeric validations
  if (config.maxRetries !== undefined && config.maxRetries < 0) {
    throw new ElasticsearchConfigError(
      '"maxRetries" must be non-negative',
      'maxRetries'
    );
  }

  if (config.requestTimeout !== undefined && config.requestTimeout < 0) {
    throw new ElasticsearchConfigError(
      '"requestTimeout" must be non-negative',
      'requestTimeout'
    );
  }
}

/**
 * Validate URL format
 */
function isValidUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    return parsed.protocol === 'http:' || parsed.protocol === 'https:';
  } catch {
    return false;
  }
}

/**
 * Validate Elasticsearch index name
 * @see https://www.elastic.co/guide/en/elasticsearch/reference/current/indices-create-index.html#indices-create-api-path-params
 */
function isValidIndexName(name: string): boolean {
  // Must be lowercase
  if (name !== name.toLowerCase()) {
    return false;
  }

  // Cannot start with -, _, +
  if (/^[-_+]/.test(name)) {
    return false;
  }

  // Cannot contain special characters
  if (/[\\/*?"<>| ,#:]/.test(name)) {
    return false;
  }

  // Cannot be . or ..
  if (name === '.' || name === '..') {
    return false;
  }

  // Must be <= 255 bytes
  if (Buffer.byteLength(name, 'utf8') > 255) {
    return false;
  }

  return name.length > 0;
}

/**
 * Validate similarity metric
 */
function isValidSimilarity(similarity: string): similarity is SimilarityMetric {
  return ['cosine', 'dot_product', 'l2_norm'].includes(similarity);
}

// ============================================================================
// Document Validation
// ============================================================================

/**
 * Validate a document for indexing
 */
export function validateDocument(
  doc: Document,
  embeddingDims: number,
  requireEmbedding: boolean = false
): void {
  // Content validation
  if (typeof doc.content !== 'string') {
    throw new ElasticsearchValidationError(
      'Document content must be a string',
      'content'
    );
  }

  if (doc.content.length === 0) {
    throw new ElasticsearchValidationError(
      'Document content cannot be empty',
      'content'
    );
  }

  // ID validation
  if (doc.id !== undefined && typeof doc.id !== 'string') {
    throw new ElasticsearchValidationError(
      'Document id must be a string',
      'id'
    );
  }

  // Embedding validation
  if (requireEmbedding && !doc.embedding) {
    throw new ElasticsearchEmbeddingError(
      'Document embedding is required',
      embeddingDims
    );
  }

  if (doc.embedding) {
    validateEmbedding(doc.embedding, embeddingDims);
  }

  // Metadata validation
  if (doc.metadata !== undefined && typeof doc.metadata !== 'object') {
    throw new ElasticsearchValidationError(
      'Document metadata must be an object',
      'metadata'
    );
  }
}

/**
 * Validate an embedding vector
 */
export function validateEmbedding(
  embedding: unknown,
  expectedDims: number
): asserts embedding is number[] {
  if (!Array.isArray(embedding)) {
    throw new ElasticsearchEmbeddingError(
      'Embedding must be an array',
      expectedDims
    );
  }

  if (embedding.length !== expectedDims) {
    throw new ElasticsearchEmbeddingError(
      `Embedding dimension mismatch: expected ${expectedDims}, got ${embedding.length}`,
      expectedDims,
      embedding.length
    );
  }

  for (let i = 0; i < embedding.length; i++) {
    const value = embedding[i];
    if (typeof value !== 'number' || isNaN(value)) {
      throw new ElasticsearchEmbeddingError(
        `Embedding contains invalid value at index ${i}: ${value}`,
        expectedDims,
        embedding.length
      );
    }

    // Check for infinity
    if (!isFinite(value)) {
      throw new ElasticsearchEmbeddingError(
        `Embedding contains infinite value at index ${i}`,
        expectedDims,
        embedding.length
      );
    }
  }
}

/**
 * Validate multiple documents
 */
export function validateDocuments(
  docs: Document[],
  embeddingDims: number,
  requireEmbedding: boolean = false
): void {
  if (!Array.isArray(docs)) {
    throw new ElasticsearchValidationError(
      'Documents must be an array',
      'documents'
    );
  }

  if (docs.length === 0) {
    throw new ElasticsearchValidationError(
      'Documents array cannot be empty',
      'documents'
    );
  }

  for (let i = 0; i < docs.length; i++) {
    try {
      validateDocument(docs[i], embeddingDims, requireEmbedding);
    } catch (error) {
      if (error instanceof ElasticsearchValidationError) {
        throw new ElasticsearchValidationError(
          `Document at index ${i}: ${error.message}`,
          `documents[${i}].${error.field}`
        );
      }
      throw error;
    }
  }
}

// ============================================================================
// Search Options Validation
// ============================================================================

/**
 * Validate retrieve options
 */
export function validateRetrieveOptions(options: RetrieveOptions): void {
  if (options.k !== undefined) {
    if (typeof options.k !== 'number' || options.k < 1) {
      throw new ElasticsearchValidationError(
        '"k" must be a positive number',
        'k'
      );
    }
    if (options.k > 10000) {
      throw new ElasticsearchValidationError(
        '"k" cannot exceed 10000',
        'k'
      );
    }
  }

  if (options.numCandidates !== undefined) {
    if (typeof options.numCandidates !== 'number' || options.numCandidates < 1) {
      throw new ElasticsearchValidationError(
        '"numCandidates" must be a positive number',
        'numCandidates'
      );
    }
    const k = options.k ?? 10;
    if (options.numCandidates < k) {
      throw new ElasticsearchValidationError(
        '"numCandidates" must be >= "k"',
        'numCandidates'
      );
    }
  }

  if (options.minScore !== undefined) {
    if (typeof options.minScore !== 'number') {
      throw new ElasticsearchValidationError(
        '"minScore" must be a number',
        'minScore'
      );
    }
  }
}

/**
 * Validate hybrid search options
 */
export function validateHybridSearchOptions(options: HybridSearchOptions): void {
  validateRetrieveOptions(options);

  if (options.vectorWeight !== undefined) {
    if (
      typeof options.vectorWeight !== 'number' ||
      options.vectorWeight < 0 ||
      options.vectorWeight > 1
    ) {
      throw new ElasticsearchValidationError(
        '"vectorWeight" must be a number between 0 and 1',
        'vectorWeight'
      );
    }
  }

  if (options.textWeight !== undefined) {
    if (
      typeof options.textWeight !== 'number' ||
      options.textWeight < 0 ||
      options.textWeight > 1
    ) {
      throw new ElasticsearchValidationError(
        '"textWeight" must be a number between 0 and 1',
        'textWeight'
      );
    }
  }

  // Validate weights sum
  const vectorWeight = options.vectorWeight ?? 0.5;
  const textWeight = options.textWeight ?? 0.5;
  const weightSum = vectorWeight + textWeight;

  if (Math.abs(weightSum - 1.0) > 0.001) {
    console.warn(
      `Warning: vectorWeight (${vectorWeight}) + textWeight (${textWeight}) = ${weightSum}, not 1.0`
    );
  }

  if (options.textFields !== undefined) {
    if (!Array.isArray(options.textFields)) {
      throw new ElasticsearchValidationError(
        '"textFields" must be an array',
        'textFields'
      );
    }
    for (const field of options.textFields) {
      if (typeof field !== 'string') {
        throw new ElasticsearchValidationError(
          '"textFields" must contain only strings',
          'textFields'
        );
      }
    }
  }
}

// ============================================================================
// Index Settings Validation
// ============================================================================

/**
 * Validate index settings
 */
export function validateIndexSettings(settings: IndexSettings): void {
  if (settings.numberOfShards !== undefined) {
    if (
      typeof settings.numberOfShards !== 'number' ||
      settings.numberOfShards < 1
    ) {
      throw new ElasticsearchValidationError(
        '"numberOfShards" must be a positive number',
        'numberOfShards'
      );
    }
  }

  if (settings.numberOfReplicas !== undefined) {
    if (
      typeof settings.numberOfReplicas !== 'number' ||
      settings.numberOfReplicas < 0
    ) {
      throw new ElasticsearchValidationError(
        '"numberOfReplicas" must be a non-negative number',
        'numberOfReplicas'
      );
    }
  }

  if (settings.refreshInterval !== undefined) {
    if (typeof settings.refreshInterval !== 'string') {
      throw new ElasticsearchValidationError(
        '"refreshInterval" must be a string',
        'refreshInterval'
      );
    }
  }

  if (settings.knn?.algoParam) {
    const { m, efConstruction } = settings.knn.algoParam;

    if (m !== undefined && (typeof m !== 'number' || m < 2 || m > 100)) {
      throw new ElasticsearchValidationError(
        '"knn.algoParam.m" must be a number between 2 and 100',
        'knn.algoParam.m'
      );
    }

    if (
      efConstruction !== undefined &&
      (typeof efConstruction !== 'number' || efConstruction < 1)
    ) {
      throw new ElasticsearchValidationError(
        '"knn.algoParam.efConstruction" must be a positive number',
        'knn.algoParam.efConstruction'
      );
    }
  }
}

// ============================================================================
// Utility Functions
// ============================================================================

/**
 * Normalize embedding vector (L2 normalization)
 */
export function normalizeEmbedding(embedding: number[]): number[] {
  const magnitude = Math.sqrt(
    embedding.reduce((sum, val) => sum + val * val, 0)
  );

  if (magnitude === 0) {
    return embedding;
  }

  return embedding.map((val) => val / magnitude);
}

/**
 * Check if embeddings are normalized (magnitude close to 1)
 */
export function isNormalizedEmbedding(embedding: number[], tolerance = 0.001): boolean {
  const magnitude = Math.sqrt(
    embedding.reduce((sum, val) => sum + val * val, 0)
  );
  return Math.abs(magnitude - 1.0) < tolerance;
}

/**
 * Generate a unique document ID
 */
export function generateDocumentId(): string {
  const timestamp = Date.now().toString(36);
  const random = Math.random().toString(36).substring(2, 10);
  return `${timestamp}-${random}`;
}

/**
 * Sanitize index name
 */
export function sanitizeIndexName(name: string): string {
  return name
    .toLowerCase()
    .replace(/^[-_+]+/, '')
    .replace(/[\\/*?"<>| ,#:]/g, '-')
    .substring(0, 255);
}