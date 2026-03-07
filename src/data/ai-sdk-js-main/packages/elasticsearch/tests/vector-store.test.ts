// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * ElasticsearchVectorStore Unit Tests
 *
 * Comprehensive test suite for the main vector store class
 * covering document indexing, retrieval, and search operations.
 */

import {
  ElasticsearchVectorStore,
  createVectorStore,
  createUninitializedVectorStore,
  ElasticsearchError,
  ElasticsearchIndexError,
  ElasticsearchIndexNotFoundError,
  ElasticsearchValidationError,
  ElasticsearchBulkError,
  validateConfig,
  validateDocument,
  validateEmbedding,
  generateDocumentId,
  sanitizeIndexName,
  normalizeEmbedding,
  DEFAULT_CONFIG,
  DEFAULT_RETRIEVE_OPTIONS,
  isDocument,
  isIndexedDocument,
  isEmbeddingVector,
  isSimilarityMetric,
} from '../src/index.js';

// ============================================================================
// Mock Client
// ============================================================================

function createMockClient(options: {
  indexExists?: boolean;
  searchResults?: any[];
  bulkErrors?: boolean;
  throwOnSearch?: Error;
  throwOnBulk?: Error;
  throwOnCreate?: Error;
} = {}) {
  const {
    indexExists = true,
    searchResults = [],
    bulkErrors = false,
    throwOnSearch,
    throwOnBulk,
    throwOnCreate,
  } = options;

  return {
    search: jest.fn().mockImplementation(async () => {
      if (throwOnSearch) throw throwOnSearch;
      return {
        hits: {
          hits: searchResults.map((r, i) => ({
            _id: r.id || `doc-${i}`,
            _score: r.score || 1 - (i * 0.1),
            _source: {
              content: r.content || `Content ${i}`,
              embedding: r.embedding || Array(10).fill(0.1),
              metadata: r.metadata || {},
            },
            highlight: r.highlight,
          })),
          total: { value: searchResults.length },
        },
        took: 10,
      };
    }),
    
    index: jest.fn().mockResolvedValue({ result: 'created' }),
    
    bulk: jest.fn().mockImplementation(async () => {
      if (throwOnBulk) throw throwOnBulk;
      return {
        errors: bulkErrors,
        items: bulkErrors 
          ? [{ index: { _id: 'doc-1', error: { reason: 'test error' } } }]
          : [{ index: { _id: 'doc-1', result: 'created' } }],
        took: 5,
      };
    }),
    
    delete: jest.fn().mockResolvedValue({ result: 'deleted' }),
    
    deleteByQuery: jest.fn().mockResolvedValue({ deleted: 5 }),
    
    get: jest.fn().mockImplementation(async ({ id }) => ({
      _id: id,
      _source: {
        content: 'Test content',
        embedding: Array(10).fill(0.1),
        metadata: {},
      },
      found: true,
    })),
    
    mget: jest.fn().mockImplementation(async ({ body }) => ({
      docs: body.ids.map((id: string) => ({
        _id: id,
        _source: {
          content: `Content for ${id}`,
          embedding: Array(10).fill(0.1),
          metadata: {},
        },
        found: true,
      })),
    })),
    
    count: jest.fn().mockResolvedValue({ count: 100 }),
    
    indices: {
      exists: jest.fn().mockResolvedValue(indexExists),
      create: jest.fn().mockImplementation(async () => {
        if (throwOnCreate) throw throwOnCreate;
        return { acknowledged: true };
      }),
      delete: jest.fn().mockResolvedValue({ acknowledged: true }),
      refresh: jest.fn().mockResolvedValue({}),
      stats: jest.fn().mockResolvedValue({
        indices: {
          'test-index': {
            primaries: {
              docs: { count: 100, deleted: 5 },
              store: { size_in_bytes: 1024000 },
            },
          },
        },
      }),
      putSettings: jest.fn().mockResolvedValue({}),
      getSettings: jest.fn().mockResolvedValue({}),
      putMapping: jest.fn().mockResolvedValue({}),
      getMapping: jest.fn().mockResolvedValue({}),
    },
    
    info: jest.fn().mockResolvedValue({
      version: { number: '8.11.0' },
      cluster_name: 'test-cluster',
    }),
    
    ping: jest.fn().mockResolvedValue(true),
  };
}

// ============================================================================
// Configuration Tests
// ============================================================================

describe('ElasticsearchVectorStore - Configuration', () => {
  describe('DEFAULT_CONFIG', () => {
    it('should have valid default values', () => {
      expect(DEFAULT_CONFIG.node).toBe('http://localhost:9200');
      expect(DEFAULT_CONFIG.indexName).toBe('documents');
      expect(DEFAULT_CONFIG.embeddingDimension).toBe(1536);
      expect(DEFAULT_CONFIG.similarity).toBe('cosine');
      expect(DEFAULT_CONFIG.contentField).toBe('content');
      expect(DEFAULT_CONFIG.embeddingField).toBe('embedding');
      expect(DEFAULT_CONFIG.metadataField).toBe('metadata');
    });
  });

  describe('validateConfig', () => {
    it('should accept valid minimal config', () => {
      expect(() => validateConfig({ node: 'http://localhost:9200' })).not.toThrow();
    });

    it('should accept Elastic Cloud config', () => {
      expect(() => validateConfig({
        cloud: { id: 'my-deployment:xxxx' },
        auth: { apiKey: 'my-key' },
      })).not.toThrow();
    });

    it('should reject missing node and cloud', () => {
      expect(() => validateConfig({} as any)).toThrow();
    });

    it('should reject invalid node URL', () => {
      expect(() => validateConfig({ node: 'not-a-url' })).toThrow();
    });

    it('should reject negative embeddingDimension', () => {
      expect(() => validateConfig({
        node: 'http://localhost:9200',
        embeddingDimension: -10,
      })).toThrow();
    });

    it('should reject invalid similarity metric', () => {
      expect(() => validateConfig({
        node: 'http://localhost:9200',
        similarity: 'invalid' as any,
      })).toThrow();
    });
  });
});

// ============================================================================
// Document Validation Tests
// ============================================================================

describe('ElasticsearchVectorStore - Document Validation', () => {
  describe('validateDocument', () => {
    it('should accept valid document with id', () => {
      const doc = { id: 'doc-1', content: 'test', embedding: [0.1, 0.2] };
      expect(() => validateDocument(doc)).not.toThrow();
    });

    it('should accept valid document without id', () => {
      const doc = { content: 'test', embedding: [0.1, 0.2] };
      expect(() => validateDocument(doc)).not.toThrow();
    });

    it('should reject empty content', () => {
      const doc = { content: '', embedding: [0.1, 0.2] };
      expect(() => validateDocument(doc)).toThrow();
    });

    it('should reject invalid embedding', () => {
      const doc = { content: 'test', embedding: 'not-an-array' as any };
      expect(() => validateDocument(doc)).toThrow();
    });

    it('should reject embedding with non-numbers', () => {
      const doc = { content: 'test', embedding: [0.1, 'bad', 0.3] as any };
      expect(() => validateDocument(doc)).toThrow();
    });

    it('should accept document with metadata', () => {
      const doc = {
        content: 'test',
        embedding: [0.1, 0.2],
        metadata: { source: 'test', count: 10 },
      };
      expect(() => validateDocument(doc)).not.toThrow();
    });
  });

  describe('validateEmbedding', () => {
    it('should accept valid embedding array', () => {
      expect(() => validateEmbedding([0.1, 0.2, 0.3])).not.toThrow();
    });

    it('should reject empty array', () => {
      expect(() => validateEmbedding([])).toThrow();
    });

    it('should reject non-array', () => {
      expect(() => validateEmbedding('not-array' as any)).toThrow();
    });

    it('should reject array with NaN', () => {
      expect(() => validateEmbedding([0.1, NaN, 0.3])).toThrow();
    });

    it('should reject array with Infinity', () => {
      expect(() => validateEmbedding([0.1, Infinity, 0.3])).toThrow();
    });
  });

  describe('isDocument', () => {
    it('should return true for valid document', () => {
      expect(isDocument({ content: 'test', embedding: [0.1] })).toBe(true);
    });

    it('should return false for missing content', () => {
      expect(isDocument({ embedding: [0.1] } as any)).toBe(false);
    });

    it('should return false for missing embedding', () => {
      expect(isDocument({ content: 'test' } as any)).toBe(false);
    });

    it('should return false for non-object', () => {
      expect(isDocument('string' as any)).toBe(false);
      expect(isDocument(null as any)).toBe(false);
    });
  });

  describe('isIndexedDocument', () => {
    it('should return true for document with id', () => {
      expect(isIndexedDocument({ id: '1', content: 'test', embedding: [0.1] })).toBe(true);
    });

    it('should return false for document without id', () => {
      expect(isIndexedDocument({ content: 'test', embedding: [0.1] } as any)).toBe(false);
    });
  });
});

// ============================================================================
// Utility Function Tests
// ============================================================================

describe('ElasticsearchVectorStore - Utilities', () => {
  describe('generateDocumentId', () => {
    it('should generate unique IDs', () => {
      const id1 = generateDocumentId();
      const id2 = generateDocumentId();
      expect(id1).not.toBe(id2);
    });

    it('should generate string IDs', () => {
      expect(typeof generateDocumentId()).toBe('string');
    });

    it('should generate non-empty IDs', () => {
      expect(generateDocumentId().length).toBeGreaterThan(0);
    });
  });

  describe('sanitizeIndexName', () => {
    it('should lowercase name', () => {
      expect(sanitizeIndexName('MyIndex')).toBe('myindex');
    });

    it('should replace spaces with hyphens', () => {
      expect(sanitizeIndexName('my index')).toBe('my-index');
    });

    it('should remove special characters', () => {
      expect(sanitizeIndexName('my@index!')).toBe('myindex');
    });

    it('should remove leading underscores', () => {
      expect(sanitizeIndexName('_myindex')).toBe('myindex');
    });
  });

  describe('normalizeEmbedding', () => {
    it('should normalize to unit length', () => {
      const embedding = [3, 4]; // length = 5
      const normalized = normalizeEmbedding(embedding);
      expect(normalized[0]).toBeCloseTo(0.6);
      expect(normalized[1]).toBeCloseTo(0.8);
    });

    it('should handle already normalized vectors', () => {
      const embedding = [0.6, 0.8]; // already unit length
      const normalized = normalizeEmbedding(embedding);
      expect(normalized[0]).toBeCloseTo(0.6);
      expect(normalized[1]).toBeCloseTo(0.8);
    });

    it('should handle zero vector', () => {
      const embedding = [0, 0, 0];
      const normalized = normalizeEmbedding(embedding);
      expect(normalized.every((v) => v === 0)).toBe(true);
    });
  });

  describe('isEmbeddingVector', () => {
    it('should return true for valid vector', () => {
      expect(isEmbeddingVector([0.1, 0.2, 0.3])).toBe(true);
    });

    it('should return false for empty array', () => {
      expect(isEmbeddingVector([])).toBe(false);
    });

    it('should return false for array with strings', () => {
      expect(isEmbeddingVector(['a', 'b'])).toBe(false);
    });
  });

  describe('isSimilarityMetric', () => {
    it('should return true for valid metrics', () => {
      expect(isSimilarityMetric('cosine')).toBe(true);
      expect(isSimilarityMetric('dot_product')).toBe(true);
      expect(isSimilarityMetric('l2_norm')).toBe(true);
    });

    it('should return false for invalid metrics', () => {
      expect(isSimilarityMetric('invalid')).toBe(false);
      expect(isSimilarityMetric('')).toBe(false);
    });
  });
});

// ============================================================================
// Vector Store Initialization Tests
// ============================================================================

describe('ElasticsearchVectorStore - Initialization', () => {
  describe('createVectorStore', () => {
    it('should create store with provided client', async () => {
      const mockClient = createMockClient();
      const store = await createVectorStore(mockClient as any, 'test-index');
      
      expect(store).toBeInstanceOf(ElasticsearchVectorStore);
      expect(store.indexName).toBe('test-index');
    });

    it('should create index if not exists', async () => {
      const mockClient = createMockClient({ indexExists: false });
      await createVectorStore(mockClient as any, 'test-index');
      
      expect(mockClient.indices.create).toHaveBeenCalled();
    });

    it('should not create index if exists', async () => {
      const mockClient = createMockClient({ indexExists: true });
      await createVectorStore(mockClient as any, 'test-index');
      
      expect(mockClient.indices.create).not.toHaveBeenCalled();
    });

    it('should apply custom config', async () => {
      const mockClient = createMockClient();
      const store = await createVectorStore(mockClient as any, 'test-index', {
        embeddingDimension: 768,
        similarity: 'dot_product',
      });
      
      expect(store.config.embeddingDimension).toBe(768);
      expect(store.config.similarity).toBe('dot_product');
    });
  });

  describe('createUninitializedVectorStore', () => {
    it('should create store without initialization', () => {
      const mockClient = createMockClient();
      const store = createUninitializedVectorStore(mockClient as any, 'test-index');
      
      expect(store).toBeInstanceOf(ElasticsearchVectorStore);
      expect(mockClient.indices.exists).not.toHaveBeenCalled();
    });
  });
});

// ============================================================================
// Document Operations Tests
// ============================================================================

describe('ElasticsearchVectorStore - Document Operations', () => {
  let store: ElasticsearchVectorStore;
  let mockClient: ReturnType<typeof createMockClient>;

  beforeEach(async () => {
    mockClient = createMockClient();
    store = await createVectorStore(mockClient as any, 'test-index');
  });

  describe('upsertDocument', () => {
    it('should index single document', async () => {
      const doc = {
        id: 'doc-1',
        content: 'Test content',
        embedding: Array(1536).fill(0.1),
      };
      
      const result = await store.upsertDocument(doc);
      
      expect(mockClient.index).toHaveBeenCalledWith(
        expect.objectContaining({
          index: 'test-index',
          id: 'doc-1',
        })
      );
      expect(result).toBe('doc-1');
    });

    it('should generate ID if not provided', async () => {
      const doc = {
        content: 'Test content',
        embedding: Array(1536).fill(0.1),
      };
      
      const result = await store.upsertDocument(doc);
      
      expect(typeof result).toBe('string');
      expect(result.length).toBeGreaterThan(0);
    });

    it('should include metadata', async () => {
      const doc = {
        id: 'doc-1',
        content: 'Test content',
        embedding: Array(1536).fill(0.1),
        metadata: { source: 'test', category: 'docs' },
      };
      
      await store.upsertDocument(doc);
      
      expect(mockClient.index).toHaveBeenCalledWith(
        expect.objectContaining({
          body: expect.objectContaining({
            metadata: { source: 'test', category: 'docs' },
          }),
        })
      );
    });
  });

  describe('upsertDocuments (bulk)', () => {
    it('should bulk index multiple documents', async () => {
      const docs = [
        { id: 'doc-1', content: 'Content 1', embedding: Array(1536).fill(0.1) },
        { id: 'doc-2', content: 'Content 2', embedding: Array(1536).fill(0.2) },
        { id: 'doc-3', content: 'Content 3', embedding: Array(1536).fill(0.3) },
      ];
      
      const result = await store.upsertDocuments(docs);
      
      expect(mockClient.bulk).toHaveBeenCalled();
      expect(result.successful).toBe(docs.length);
      expect(result.failed).toBe(0);
    });

    it('should handle bulk errors', async () => {
      mockClient = createMockClient({ bulkErrors: true });
      store = await createVectorStore(mockClient as any, 'test-index');
      
      const docs = [
        { id: 'doc-1', content: 'Content 1', embedding: Array(1536).fill(0.1) },
      ];
      
      const result = await store.upsertDocuments(docs);
      
      expect(result.failed).toBeGreaterThan(0);
      expect(result.errors.length).toBeGreaterThan(0);
    });

    it('should batch large document sets', async () => {
      const docs = Array(150).fill(null).map((_, i) => ({
        id: `doc-${i}`,
        content: `Content ${i}`,
        embedding: Array(1536).fill(0.1),
      }));
      
      await store.upsertDocuments(docs, { batchSize: 50 });
      
      // Should be called 3 times (150/50 = 3 batches)
      expect(mockClient.bulk).toHaveBeenCalledTimes(3);
    });

    it('should call progress callback', async () => {
      const docs = Array(100).fill(null).map((_, i) => ({
        id: `doc-${i}`,
        content: `Content ${i}`,
        embedding: Array(1536).fill(0.1),
      }));
      
      const onProgress = jest.fn();
      await store.upsertDocuments(docs, { batchSize: 25, onProgress });
      
      expect(onProgress).toHaveBeenCalledTimes(4); // 4 batches
    });
  });

  describe('deleteDocument', () => {
    it('should delete document by ID', async () => {
      await store.deleteDocument('doc-1');
      
      expect(mockClient.delete).toHaveBeenCalledWith({
        index: 'test-index',
        id: 'doc-1',
      });
    });
  });

  describe('deleteDocuments', () => {
    it('should delete multiple documents', async () => {
      const ids = ['doc-1', 'doc-2', 'doc-3'];
      await store.deleteDocuments(ids);
      
      expect(mockClient.delete).toHaveBeenCalledTimes(3);
    });
  });

  describe('deleteByQuery', () => {
    it('should delete by query', async () => {
      await store.deleteByQuery({
        bool: { must: [{ term: { 'metadata.source': 'test' } }] },
      });
      
      expect(mockClient.deleteByQuery).toHaveBeenCalledWith(
        expect.objectContaining({
          index: 'test-index',
        })
      );
    });
  });

  describe('getDocument', () => {
    it('should retrieve document by ID', async () => {
      const doc = await store.getDocument('doc-1');
      
      expect(mockClient.get).toHaveBeenCalledWith({
        index: 'test-index',
        id: 'doc-1',
      });
      expect(doc).toBeDefined();
      expect(doc?.id).toBe('doc-1');
    });
  });

  describe('getDocuments', () => {
    it('should retrieve multiple documents', async () => {
      const ids = ['doc-1', 'doc-2'];
      const docs = await store.getDocuments(ids);
      
      expect(mockClient.mget).toHaveBeenCalled();
      expect(docs).toHaveLength(2);
    });
  });
});

// ============================================================================
// Search Tests
// ============================================================================

describe('ElasticsearchVectorStore - Search', () => {
  let store: ElasticsearchVectorStore;
  let mockClient: ReturnType<typeof createMockClient>;

  beforeEach(async () => {
    mockClient = createMockClient({
      searchResults: [
        { id: 'doc-1', content: 'First result', score: 0.95 },
        { id: 'doc-2', content: 'Second result', score: 0.85 },
        { id: 'doc-3', content: 'Third result', score: 0.75 },
      ],
    });
    store = await createVectorStore(mockClient as any, 'test-index');
  });

  describe('retrieve (kNN search)', () => {
    it('should perform kNN search', async () => {
      const embedding = Array(1536).fill(0.1);
      const results = await store.retrieve(embedding);
      
      expect(mockClient.search).toHaveBeenCalled();
      expect(results).toHaveLength(3);
      expect(results[0].score).toBeGreaterThan(results[1].score);
    });

    it('should respect topK option', async () => {
      const embedding = Array(1536).fill(0.1);
      await store.retrieve(embedding, { topK: 5 });
      
      expect(mockClient.search).toHaveBeenCalledWith(
        expect.objectContaining({
          knn: expect.objectContaining({
            k: 5,
          }),
        })
      );
    });

    it('should apply metadata filter', async () => {
      const embedding = Array(1536).fill(0.1);
      await store.retrieve(embedding, {
        filter: { term: { 'metadata.source': 'test' } },
      });
      
      expect(mockClient.search).toHaveBeenCalledWith(
        expect.objectContaining({
          knn: expect.objectContaining({
            filter: expect.anything(),
          }),
        })
      );
    });

    it('should apply minimum score threshold', async () => {
      const embedding = Array(1536).fill(0.1);
      const results = await store.retrieve(embedding, { minScore: 0.8 });
      
      // Should filter results below 0.8
      expect(results.every((r) => r.score >= 0.8)).toBe(true);
    });
  });

  describe('search (text search)', () => {
    it('should perform text search', async () => {
      const results = await store.search('test query');
      
      expect(mockClient.search).toHaveBeenCalled();
      expect(results.length).toBeGreaterThan(0);
    });

    it('should search specific fields', async () => {
      await store.search('test query', { fields: ['content', 'metadata.title'] });
      
      expect(mockClient.search).toHaveBeenCalledWith(
        expect.objectContaining({
          query: expect.objectContaining({
            multi_match: expect.objectContaining({
              fields: ['content', 'metadata.title'],
            }),
          }),
        })
      );
    });
  });

  describe('hybridSearch', () => {
    it('should combine kNN and text search', async () => {
      const embedding = Array(1536).fill(0.1);
      const results = await store.hybridSearch('test query', embedding);
      
      expect(mockClient.search).toHaveBeenCalled();
      expect(results.length).toBeGreaterThan(0);
    });

    it('should apply vector weight', async () => {
      const embedding = Array(1536).fill(0.1);
      await store.hybridSearch('test query', embedding, {
        vectorWeight: 0.7,
        textWeight: 0.3,
      });
      
      expect(mockClient.search).toHaveBeenCalled();
    });
  });
});

// ============================================================================
// Index Management Tests
// ============================================================================

describe('ElasticsearchVectorStore - Index Management', () => {
  let store: ElasticsearchVectorStore;
  let mockClient: ReturnType<typeof createMockClient>;

  beforeEach(async () => {
    mockClient = createMockClient();
    store = await createVectorStore(mockClient as any, 'test-index');
  });

  describe('ensureIndex', () => {
    it('should create index if not exists', async () => {
      mockClient.indices.exists.mockResolvedValue(false);
      
      await store.ensureIndex();
      
      expect(mockClient.indices.create).toHaveBeenCalled();
    });

    it('should not create if exists', async () => {
      mockClient.indices.exists.mockResolvedValue(true);
      mockClient.indices.create.mockClear();
      
      await store.ensureIndex();
      
      expect(mockClient.indices.create).not.toHaveBeenCalled();
    });
  });

  describe('deleteIndex', () => {
    it('should delete index', async () => {
      await store.deleteIndex();
      
      expect(mockClient.indices.delete).toHaveBeenCalledWith({
        index: 'test-index',
      });
    });
  });

  describe('refreshIndex', () => {
    it('should refresh index', async () => {
      await store.refreshIndex();
      
      expect(mockClient.indices.refresh).toHaveBeenCalledWith({
        index: 'test-index',
      });
    });
  });

  describe('getStats', () => {
    it('should return index stats', async () => {
      const stats = await store.getStats();
      
      expect(mockClient.indices.stats).toHaveBeenCalled();
      expect(stats).toBeDefined();
    });
  });

  describe('count', () => {
    it('should return document count', async () => {
      const count = await store.count();
      
      expect(mockClient.count).toHaveBeenCalledWith({
        index: 'test-index',
      });
      expect(count).toBe(100);
    });

    it('should apply filter query', async () => {
      await store.count({ term: { 'metadata.source': 'test' } });
      
      expect(mockClient.count).toHaveBeenCalledWith(
        expect.objectContaining({
          query: expect.anything(),
        })
      );
    });
  });
});

// ============================================================================
// Error Handling Tests
// ============================================================================

describe('ElasticsearchVectorStore - Error Handling', () => {
  describe('search errors', () => {
    it('should wrap search errors', async () => {
      const mockClient = createMockClient({
        throwOnSearch: new Error('Search failed'),
      });
      const store = await createVectorStore(mockClient as any, 'test-index');
      
      await expect(store.retrieve(Array(1536).fill(0.1))).rejects.toThrow();
    });
  });

  describe('bulk errors', () => {
    it('should handle bulk operation errors', async () => {
      const mockClient = createMockClient({
        throwOnBulk: new Error('Bulk failed'),
      });
      const store = await createVectorStore(mockClient as any, 'test-index');
      
      const docs = [{ id: 'doc-1', content: 'test', embedding: Array(1536).fill(0.1) }];
      
      await expect(store.upsertDocuments(docs)).rejects.toThrow();
    });
  });

  describe('index creation errors', () => {
    it('should handle index creation errors', async () => {
      const mockClient = createMockClient({
        indexExists: false,
        throwOnCreate: new Error('Create failed'),
      });
      
      await expect(createVectorStore(mockClient as any, 'test-index')).rejects.toThrow();
    });
  });
});

// ============================================================================
// Edge Cases Tests
// ============================================================================

describe('ElasticsearchVectorStore - Edge Cases', () => {
  let store: ElasticsearchVectorStore;
  let mockClient: ReturnType<typeof createMockClient>;

  beforeEach(async () => {
    mockClient = createMockClient();
    store = await createVectorStore(mockClient as any, 'test-index');
  });

  describe('empty operations', () => {
    it('should handle empty document array', async () => {
      const result = await store.upsertDocuments([]);
      
      expect(result.successful).toBe(0);
      expect(result.failed).toBe(0);
    });

    it('should handle empty ID array for get', async () => {
      const docs = await store.getDocuments([]);
      
      expect(docs).toEqual([]);
    });

    it('should handle empty search results', async () => {
      mockClient.search.mockResolvedValue({
        hits: { hits: [], total: { value: 0 } },
        took: 5,
      });
      
      const results = await store.retrieve(Array(1536).fill(0.1));
      
      expect(results).toEqual([]);
    });
  });

  describe('large data', () => {
    it('should handle very large embeddings', async () => {
      const largeEmbedding = Array(4096).fill(0.1);
      
      store = await createVectorStore(mockClient as any, 'test-index', {
        embeddingDimension: 4096,
      });
      
      await store.upsertDocument({
        id: 'doc-1',
        content: 'test',
        embedding: largeEmbedding,
      });
      
      expect(mockClient.index).toHaveBeenCalled();
    });

    it('should handle very long content', async () => {
      const longContent = 'x'.repeat(100000);
      
      await store.upsertDocument({
        id: 'doc-1',
        content: longContent,
        embedding: Array(1536).fill(0.1),
      });
      
      expect(mockClient.index).toHaveBeenCalled();
    });
  });

  describe('special characters', () => {
    it('should handle unicode content', async () => {
      await store.upsertDocument({
        id: 'doc-1',
        content: '日本語テスト 中文测试 한국어 테스트',
        embedding: Array(1536).fill(0.1),
      });
      
      expect(mockClient.index).toHaveBeenCalled();
    });

    it('should handle special ID characters', async () => {
      await store.upsertDocument({
        id: 'doc:1/test',
        content: 'test',
        embedding: Array(1536).fill(0.1),
      });
      
      expect(mockClient.index).toHaveBeenCalled();
    });
  });

  describe('metadata variations', () => {
    it('should handle nested metadata', async () => {
      await store.upsertDocument({
        id: 'doc-1',
        content: 'test',
        embedding: Array(1536).fill(0.1),
        metadata: {
          level1: {
            level2: {
              level3: 'deep value',
            },
          },
        },
      });
      
      expect(mockClient.index).toHaveBeenCalled();
    });

    it('should handle array metadata', async () => {
      await store.upsertDocument({
        id: 'doc-1',
        content: 'test',
        embedding: Array(1536).fill(0.1),
        metadata: {
          tags: ['tag1', 'tag2', 'tag3'],
          numbers: [1, 2, 3],
        },
      });
      
      expect(mockClient.index).toHaveBeenCalled();
    });
  });
});

// ============================================================================
// Default Options Tests
// ============================================================================

describe('ElasticsearchVectorStore - Default Options', () => {
  describe('DEFAULT_RETRIEVE_OPTIONS', () => {
    it('should have sensible defaults', () => {
      expect(DEFAULT_RETRIEVE_OPTIONS.topK).toBe(10);
      expect(DEFAULT_RETRIEVE_OPTIONS.minScore).toBeUndefined();
    });
  });
});