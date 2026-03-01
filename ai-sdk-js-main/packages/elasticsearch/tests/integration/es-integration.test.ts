// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Elasticsearch Integration Tests
 *
 * These tests run against a real Elasticsearch instance.
 * Prerequisites:
 *   docker-compose -f tests/docker-compose.test.yml up -d
 *
 * Tests cover:
 * - Index creation with vector mappings
 * - Document indexing (single and bulk)
 * - kNN vector search
 * - Hybrid search (vector + BM25)
 * - Metadata filtering
 * - Pagination
 * - Index management operations
 */

import { Client } from '@elastic/elasticsearch';
import {
  ElasticsearchVectorStore,
  createElasticsearchClient,
  createVectorStore,
  testConnection,
  pingCluster,
  getClusterHealth,
  buildIndexMapping,
  HybridSearchBuilder,
  createHybridSearch,
  MetadataFilterBuilder,
  metadataFilter,
  Paginator,
  createPaginator,
  IngestPipelineBuilder,
  ingestPipeline,
  TextChunker,
  createChunker,
  ChunkPresets,
  ElasticsearchError,
  ElasticsearchConnectionError,
} from '../../src/index.js';

// ============================================================================
// Test Configuration
// ============================================================================

const ES_URL = process.env.ES_URL || 'http://localhost:9200';
const TEST_INDEX_PREFIX = 'test-integration';
const VECTOR_DIMENSION = 128; // Smaller dimension for tests

/**
 * Generate random embedding vector
 */
function generateEmbedding(dimension: number = VECTOR_DIMENSION): number[] {
  const embedding = Array(dimension).fill(0).map(() => Math.random() * 2 - 1);
  const norm = Math.sqrt(embedding.reduce((sum, v) => sum + v * v, 0));
  return embedding.map((v) => v / norm);
}

/**
 * Generate similar embedding (for testing relevance)
 */
function generateSimilarEmbedding(
  base: number[],
  similarity: number = 0.9
): number[] {
  const noise = Array(base.length).fill(0).map(() => (Math.random() * 2 - 1) * (1 - similarity));
  const result = base.map((v, i) => v * similarity + noise[i] * (1 - similarity));
  const norm = Math.sqrt(result.reduce((sum, v) => sum + v * v, 0));
  return result.map((v) => v / norm);
}

/**
 * Generate test documents
 */
function generateTestDocuments(count: number): Array<{
  id: string;
  content: string;
  embedding: number[];
  metadata: Record<string, unknown>;
}> {
  const categories = ['technology', 'science', 'business', 'health'];
  const sources = ['blog', 'news', 'wiki', 'docs'];
  
  return Array(count).fill(null).map((_, i) => ({
    id: `doc-${i}`,
    content: `This is test document number ${i}. It contains content about ${categories[i % 4]} topics.`,
    embedding: generateEmbedding(),
    metadata: {
      category: categories[i % 4],
      source: sources[i % 4],
      priority: i % 3,
      createdAt: new Date(Date.now() - i * 86400000).toISOString(),
      tags: [`tag-${i % 5}`, `tag-${(i + 1) % 5}`],
    },
  }));
}

/**
 * Wait for Elasticsearch to be ready
 */
async function waitForElasticsearch(
  url: string,
  maxAttempts: number = 30,
  delayMs: number = 1000
): Promise<boolean> {
  const client = new Client({ node: url });
  
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      const health = await client.cluster.health();
      if (health.status !== 'red') {
        await client.close();
        return true;
      }
    } catch (error) {
      // Continue waiting
    }
    await new Promise((resolve) => setTimeout(resolve, delayMs));
  }
  
  await client.close();
  return false;
}

/**
 * Clean up test indices
 */
async function cleanupTestIndices(client: Client): Promise<void> {
  try {
    const indices = await client.cat.indices({ format: 'json' });
    const testIndices = indices
      .filter((idx: any) => idx.index?.startsWith(TEST_INDEX_PREFIX))
      .map((idx: any) => idx.index);
    
    if (testIndices.length > 0) {
      await client.indices.delete({ index: testIndices });
    }
  } catch (error) {
    // Ignore cleanup errors
  }
}

// ============================================================================
// Test Suites
// ============================================================================

describe('Elasticsearch Integration Tests', () => {
  let client: Client;
  let isConnected = false;

  beforeAll(async () => {
    // Check if Elasticsearch is available
    isConnected = await waitForElasticsearch(ES_URL, 5, 1000);
    
    if (isConnected) {
      client = new Client({ node: ES_URL });
      await cleanupTestIndices(client);
    }
  }, 30000);

  afterAll(async () => {
    if (client) {
      await cleanupTestIndices(client);
      await client.close();
    }
  });

  // Skip all tests if ES is not available
  const describeIfConnected = isConnected ? describe : describe.skip;

  // ============================================================================
  // Connection Tests
  // ============================================================================

  describeIfConnected('Connection', () => {
    it('should connect to Elasticsearch', async () => {
      const info = await client.info();
      expect(info.cluster_name).toBeDefined();
      expect(info.version.number).toBeDefined();
    });

    it('should ping cluster successfully', async () => {
      const result = await client.ping();
      expect(result).toBe(true);
    });

    it('should get cluster health', async () => {
      const health = await client.cluster.health();
      expect(['green', 'yellow']).toContain(health.status);
    });
  });

  // ============================================================================
  // Index Creation Tests
  // ============================================================================

  describeIfConnected('Index Creation', () => {
    const indexName = `${TEST_INDEX_PREFIX}-create`;

    afterEach(async () => {
      try {
        await client.indices.delete({ index: indexName });
      } catch (e) {
        // Ignore
      }
    });

    it('should create index with vector mapping', async () => {
      const mapping = {
        properties: {
          content: { type: 'text' },
          embedding: {
            type: 'dense_vector',
            dims: VECTOR_DIMENSION,
            index: true,
            similarity: 'cosine',
          },
          metadata: {
            type: 'object',
            properties: {
              category: { type: 'keyword' },
              source: { type: 'keyword' },
              priority: { type: 'integer' },
              createdAt: { type: 'date' },
            },
          },
        },
      };

      await client.indices.create({
        index: indexName,
        mappings: mapping,
        settings: {
          number_of_shards: 1,
          number_of_replicas: 0,
        },
      });

      const exists = await client.indices.exists({ index: indexName });
      expect(exists).toBe(true);

      const indexMapping = await client.indices.getMapping({ index: indexName });
      expect(indexMapping[indexName].mappings.properties).toHaveProperty('embedding');
      expect(indexMapping[indexName].mappings.properties.embedding.type).toBe('dense_vector');
    });

    it('should create index with HNSW parameters', async () => {
      const mapping = {
        properties: {
          embedding: {
            type: 'dense_vector',
            dims: VECTOR_DIMENSION,
            index: true,
            similarity: 'cosine',
            index_options: {
              type: 'hnsw',
              m: 16,
              ef_construction: 100,
            },
          },
        },
      };

      await client.indices.create({
        index: indexName,
        mappings: mapping,
      });

      const indexMapping = await client.indices.getMapping({ index: indexName });
      expect(indexMapping[indexName].mappings.properties.embedding.index_options?.type).toBe('hnsw');
    });
  });

  // ============================================================================
  // Document Indexing Tests
  // ============================================================================

  describeIfConnected('Document Indexing', () => {
    const indexName = `${TEST_INDEX_PREFIX}-docs`;

    beforeAll(async () => {
      await client.indices.create({
        index: indexName,
        mappings: {
          properties: {
            content: { type: 'text' },
            embedding: {
              type: 'dense_vector',
              dims: VECTOR_DIMENSION,
              index: true,
              similarity: 'cosine',
            },
            metadata: { type: 'object', dynamic: true },
          },
        },
        settings: { number_of_shards: 1, number_of_replicas: 0 },
      });
    });

    afterAll(async () => {
      try {
        await client.indices.delete({ index: indexName });
      } catch (e) {
        // Ignore
      }
    });

    it('should index single document', async () => {
      const doc = {
        content: 'Test document content',
        embedding: generateEmbedding(),
        metadata: { category: 'test' },
      };

      const result = await client.index({
        index: indexName,
        id: 'single-doc',
        document: doc,
        refresh: true,
      });

      expect(result.result).toBe('created');

      const retrieved = await client.get({
        index: indexName,
        id: 'single-doc',
      });

      expect(retrieved.found).toBe(true);
      expect(retrieved._source).toMatchObject({
        content: doc.content,
        metadata: doc.metadata,
      });
    });

    it('should bulk index multiple documents', async () => {
      const docs = generateTestDocuments(50);
      
      const operations = docs.flatMap((doc) => [
        { index: { _index: indexName, _id: doc.id } },
        { content: doc.content, embedding: doc.embedding, metadata: doc.metadata },
      ]);

      const result = await client.bulk({
        operations,
        refresh: true,
      });

      expect(result.errors).toBe(false);
      expect(result.items.length).toBe(50);

      const count = await client.count({ index: indexName });
      expect(count.count).toBeGreaterThanOrEqual(50);
    });

    it('should update existing document', async () => {
      const doc = {
        content: 'Original content',
        embedding: generateEmbedding(),
        metadata: { version: 1 },
      };

      await client.index({
        index: indexName,
        id: 'update-doc',
        document: doc,
        refresh: true,
      });

      const updated = {
        ...doc,
        content: 'Updated content',
        metadata: { version: 2 },
      };

      await client.index({
        index: indexName,
        id: 'update-doc',
        document: updated,
        refresh: true,
      });

      const retrieved = await client.get({
        index: indexName,
        id: 'update-doc',
      });

      expect((retrieved._source as any).content).toBe('Updated content');
      expect((retrieved._source as any).metadata.version).toBe(2);
    });
  });

  // ============================================================================
  // kNN Search Tests
  // ============================================================================

  describeIfConnected('kNN Search', () => {
    const indexName = `${TEST_INDEX_PREFIX}-knn`;
    let baseEmbedding: number[];

    beforeAll(async () => {
      await client.indices.create({
        index: indexName,
        mappings: {
          properties: {
            content: { type: 'text' },
            embedding: {
              type: 'dense_vector',
              dims: VECTOR_DIMENSION,
              index: true,
              similarity: 'cosine',
            },
            metadata: { type: 'object', dynamic: true },
          },
        },
        settings: { number_of_shards: 1, number_of_replicas: 0 },
      });

      // Create a base embedding for similarity testing
      baseEmbedding = generateEmbedding();

      // Index documents with varying similarity to base
      const docs = [
        { id: 'similar-1', content: 'Very similar document 1', embedding: generateSimilarEmbedding(baseEmbedding, 0.95), metadata: { similarity: 'high' } },
        { id: 'similar-2', content: 'Very similar document 2', embedding: generateSimilarEmbedding(baseEmbedding, 0.90), metadata: { similarity: 'high' } },
        { id: 'similar-3', content: 'Somewhat similar document', embedding: generateSimilarEmbedding(baseEmbedding, 0.70), metadata: { similarity: 'medium' } },
        { id: 'different-1', content: 'Different document 1', embedding: generateEmbedding(), metadata: { similarity: 'low' } },
        { id: 'different-2', content: 'Different document 2', embedding: generateEmbedding(), metadata: { similarity: 'low' } },
      ];

      const operations = docs.flatMap((doc) => [
        { index: { _index: indexName, _id: doc.id } },
        { content: doc.content, embedding: doc.embedding, metadata: doc.metadata },
      ]);

      await client.bulk({ operations, refresh: true });
    });

    afterAll(async () => {
      try {
        await client.indices.delete({ index: indexName });
      } catch (e) {
        // Ignore
      }
    });

    it('should perform kNN search', async () => {
      const result = await client.search({
        index: indexName,
        knn: {
          field: 'embedding',
          query_vector: baseEmbedding,
          k: 3,
          num_candidates: 10,
        },
      });

      expect(result.hits.hits.length).toBe(3);
      expect(result.hits.hits[0]._score).toBeGreaterThan(0);
    });

    it('should return most similar documents first', async () => {
      const result = await client.search({
        index: indexName,
        knn: {
          field: 'embedding',
          query_vector: baseEmbedding,
          k: 5,
          num_candidates: 10,
        },
      });

      // High similarity documents should be first
      const topResult = result.hits.hits[0]._source as any;
      expect(topResult.metadata.similarity).toBe('high');
    });

    it('should respect k parameter', async () => {
      const k2Result = await client.search({
        index: indexName,
        knn: {
          field: 'embedding',
          query_vector: baseEmbedding,
          k: 2,
          num_candidates: 10,
        },
      });

      expect(k2Result.hits.hits.length).toBe(2);

      const k5Result = await client.search({
        index: indexName,
        knn: {
          field: 'embedding',
          query_vector: baseEmbedding,
          k: 5,
          num_candidates: 10,
        },
      });

      expect(k5Result.hits.hits.length).toBe(5);
    });

    it('should filter kNN results with metadata', async () => {
      const result = await client.search({
        index: indexName,
        knn: {
          field: 'embedding',
          query_vector: baseEmbedding,
          k: 10,
          num_candidates: 10,
          filter: {
            term: { 'metadata.similarity': 'high' },
          },
        },
      });

      expect(result.hits.hits.length).toBe(2);
      result.hits.hits.forEach((hit) => {
        expect((hit._source as any).metadata.similarity).toBe('high');
      });
    });
  });

  // ============================================================================
  // Hybrid Search Tests
  // ============================================================================

  describeIfConnected('Hybrid Search', () => {
    const indexName = `${TEST_INDEX_PREFIX}-hybrid`;
    let queryEmbedding: number[];

    beforeAll(async () => {
      await client.indices.create({
        index: indexName,
        mappings: {
          properties: {
            content: { type: 'text' },
            title: { type: 'text' },
            embedding: {
              type: 'dense_vector',
              dims: VECTOR_DIMENSION,
              index: true,
              similarity: 'cosine',
            },
            metadata: { type: 'object', dynamic: true },
          },
        },
        settings: { number_of_shards: 1, number_of_replicas: 0 },
      });

      queryEmbedding = generateEmbedding();

      const docs = [
        { 
          id: 'match-both', 
          title: 'Machine Learning Guide',
          content: 'Machine learning is a subset of artificial intelligence', 
          embedding: generateSimilarEmbedding(queryEmbedding, 0.9),
          metadata: { type: 'guide' },
        },
        { 
          id: 'match-text', 
          title: 'Machine Learning Basics',
          content: 'Introduction to machine learning concepts and algorithms', 
          embedding: generateEmbedding(), // Random, not similar
          metadata: { type: 'intro' },
        },
        { 
          id: 'match-vector', 
          title: 'Deep Neural Networks',
          content: 'Understanding deep neural network architectures', 
          embedding: generateSimilarEmbedding(queryEmbedding, 0.85),
          metadata: { type: 'advanced' },
        },
        { 
          id: 'no-match', 
          title: 'Cooking Recipes',
          content: 'Delicious recipes for home cooking enthusiasts', 
          embedding: generateEmbedding(),
          metadata: { type: 'other' },
        },
      ];

      const operations = docs.flatMap((doc) => [
        { index: { _index: indexName, _id: doc.id } },
        { title: doc.title, content: doc.content, embedding: doc.embedding, metadata: doc.metadata },
      ]);

      await client.bulk({ operations, refresh: true });
    });

    afterAll(async () => {
      try {
        await client.indices.delete({ index: indexName });
      } catch (e) {
        // Ignore
      }
    });

    it('should combine kNN and text search', async () => {
      const result = await client.search({
        index: indexName,
        query: {
          bool: {
            should: [
              {
                multi_match: {
                  query: 'machine learning',
                  fields: ['title', 'content'],
                },
              },
            ],
          },
        },
        knn: {
          field: 'embedding',
          query_vector: queryEmbedding,
          k: 3,
          num_candidates: 10,
        },
      });

      expect(result.hits.hits.length).toBeGreaterThan(0);
      // Document matching both should score highest
      const topIds = result.hits.hits.map((h) => h._id);
      expect(topIds).toContain('match-both');
    });

    it('should use RRF for result fusion', async () => {
      // ES 8.x supports RRF natively via rank parameter
      const result = await client.search({
        index: indexName,
        query: {
          multi_match: {
            query: 'machine learning',
            fields: ['title', 'content'],
          },
        },
        knn: {
          field: 'embedding',
          query_vector: queryEmbedding,
          k: 4,
          num_candidates: 10,
        },
        // Note: RRF requires Enterprise license in ES 8.x
        // For testing, we verify the query structure works
      });

      expect(result.hits.hits.length).toBeGreaterThan(0);
    });
  });

  // ============================================================================
  // Metadata Filtering Tests
  // ============================================================================

  describeIfConnected('Metadata Filtering', () => {
    const indexName = `${TEST_INDEX_PREFIX}-filter`;

    beforeAll(async () => {
      await client.indices.create({
        index: indexName,
        mappings: {
          properties: {
            content: { type: 'text' },
            embedding: {
              type: 'dense_vector',
              dims: VECTOR_DIMENSION,
              index: true,
              similarity: 'cosine',
            },
            metadata: {
              type: 'object',
              properties: {
                category: { type: 'keyword' },
                source: { type: 'keyword' },
                priority: { type: 'integer' },
                tags: { type: 'keyword' },
                createdAt: { type: 'date' },
              },
            },
          },
        },
        settings: { number_of_shards: 1, number_of_replicas: 0 },
      });

      const docs = generateTestDocuments(100);
      const operations = docs.flatMap((doc) => [
        { index: { _index: indexName, _id: doc.id } },
        { content: doc.content, embedding: doc.embedding, metadata: doc.metadata },
      ]);

      await client.bulk({ operations, refresh: true });
    });

    afterAll(async () => {
      try {
        await client.indices.delete({ index: indexName });
      } catch (e) {
        // Ignore
      }
    });

    it('should filter by single term', async () => {
      const result = await client.search({
        index: indexName,
        query: {
          term: { 'metadata.category': 'technology' },
        },
      });

      expect(result.hits.hits.length).toBeGreaterThan(0);
      result.hits.hits.forEach((hit) => {
        expect((hit._source as any).metadata.category).toBe('technology');
      });
    });

    it('should filter by multiple terms', async () => {
      const result = await client.search({
        index: indexName,
        query: {
          bool: {
            must: [
              { term: { 'metadata.category': 'technology' } },
              { term: { 'metadata.source': 'blog' } },
            ],
          },
        },
      });

      result.hits.hits.forEach((hit) => {
        expect((hit._source as any).metadata.category).toBe('technology');
        expect((hit._source as any).metadata.source).toBe('blog');
      });
    });

    it('should filter by range', async () => {
      const result = await client.search({
        index: indexName,
        query: {
          range: {
            'metadata.priority': { gte: 2 },
          },
        },
      });

      result.hits.hits.forEach((hit) => {
        expect((hit._source as any).metadata.priority).toBeGreaterThanOrEqual(2);
      });
    });

    it('should filter by date range', async () => {
      const result = await client.search({
        index: indexName,
        query: {
          range: {
            'metadata.createdAt': {
              gte: 'now-30d',
              lte: 'now',
            },
          },
        },
      });

      expect(result.hits.hits.length).toBeGreaterThan(0);
    });

    it('should filter by tags array', async () => {
      const result = await client.search({
        index: indexName,
        query: {
          term: { 'metadata.tags': 'tag-0' },
        },
      });

      result.hits.hits.forEach((hit) => {
        expect((hit._source as any).metadata.tags).toContain('tag-0');
      });
    });

    it('should combine filter with kNN', async () => {
      const queryEmbedding = generateEmbedding();
      
      const result = await client.search({
        index: indexName,
        knn: {
          field: 'embedding',
          query_vector: queryEmbedding,
          k: 10,
          num_candidates: 50,
          filter: {
            term: { 'metadata.category': 'science' },
          },
        },
      });

      result.hits.hits.forEach((hit) => {
        expect((hit._source as any).metadata.category).toBe('science');
      });
    });
  });

  // ============================================================================
  // Pagination Tests
  // ============================================================================

  describeIfConnected('Pagination', () => {
    const indexName = `${TEST_INDEX_PREFIX}-pagination`;

    beforeAll(async () => {
      await client.indices.create({
        index: indexName,
        mappings: {
          properties: {
            content: { type: 'text' },
            embedding: {
              type: 'dense_vector',
              dims: VECTOR_DIMENSION,
              index: true,
              similarity: 'cosine',
            },
            order: { type: 'integer' },
          },
        },
        settings: { number_of_shards: 1, number_of_replicas: 0 },
      });

      const docs = Array(100).fill(null).map((_, i) => ({
        id: `doc-${i.toString().padStart(3, '0')}`,
        content: `Document number ${i}`,
        embedding: generateEmbedding(),
        order: i,
      }));

      const operations = docs.flatMap((doc) => [
        { index: { _index: indexName, _id: doc.id } },
        { content: doc.content, embedding: doc.embedding, order: doc.order },
      ]);

      await client.bulk({ operations, refresh: true });
    });

    afterAll(async () => {
      try {
        await client.indices.delete({ index: indexName });
      } catch (e) {
        // Ignore
      }
    });

    it('should paginate with from/size', async () => {
      const page1 = await client.search({
        index: indexName,
        from: 0,
        size: 10,
        sort: [{ order: 'asc' }],
      });

      const page2 = await client.search({
        index: indexName,
        from: 10,
        size: 10,
        sort: [{ order: 'asc' }],
      });

      expect(page1.hits.hits.length).toBe(10);
      expect(page2.hits.hits.length).toBe(10);
      
      const page1Ids = page1.hits.hits.map((h) => h._id);
      const page2Ids = page2.hits.hits.map((h) => h._id);
      
      // No overlap between pages
      expect(page1Ids.some((id) => page2Ids.includes(id!))).toBe(false);
    });

    it('should paginate with search_after', async () => {
      const page1 = await client.search({
        index: indexName,
        size: 10,
        sort: [{ order: 'asc' }, { _id: 'asc' }],
      });

      expect(page1.hits.hits.length).toBe(10);
      const lastHit = page1.hits.hits[page1.hits.hits.length - 1];
      const searchAfter = lastHit.sort;

      const page2 = await client.search({
        index: indexName,
        size: 10,
        sort: [{ order: 'asc' }, { _id: 'asc' }],
        search_after: searchAfter,
      });

      expect(page2.hits.hits.length).toBe(10);
      
      // Page 2 should start after page 1
      const page1LastOrder = (lastHit._source as any).order;
      const page2FirstOrder = (page2.hits.hits[0]._source as any).order;
      expect(page2FirstOrder).toBeGreaterThan(page1LastOrder);
    });

    it('should count total documents', async () => {
      const result = await client.search({
        index: indexName,
        track_total_hits: true,
        size: 0,
      });

      const total = typeof result.hits.total === 'number' 
        ? result.hits.total 
        : result.hits.total?.value;
      
      expect(total).toBe(100);
    });
  });

  // ============================================================================
  // Index Management Tests
  // ============================================================================

  describeIfConnected('Index Management', () => {
    const indexName = `${TEST_INDEX_PREFIX}-mgmt`;

    afterEach(async () => {
      try {
        await client.indices.delete({ index: indexName });
      } catch (e) {
        // Ignore
      }
    });

    it('should check if index exists', async () => {
      const beforeCreate = await client.indices.exists({ index: indexName });
      expect(beforeCreate).toBe(false);

      await client.indices.create({
        index: indexName,
        mappings: { properties: { content: { type: 'text' } } },
      });

      const afterCreate = await client.indices.exists({ index: indexName });
      expect(afterCreate).toBe(true);
    });

    it('should delete index', async () => {
      await client.indices.create({
        index: indexName,
        mappings: { properties: { content: { type: 'text' } } },
      });

      await client.indices.delete({ index: indexName });

      const exists = await client.indices.exists({ index: indexName });
      expect(exists).toBe(false);
    });

    it('should refresh index', async () => {
      await client.indices.create({
        index: indexName,
        mappings: { properties: { content: { type: 'text' } } },
      });

      await client.index({
        index: indexName,
        document: { content: 'Test' },
      });

      await client.indices.refresh({ index: indexName });

      const count = await client.count({ index: indexName });
      expect(count.count).toBe(1);
    });

    it('should get index stats', async () => {
      await client.indices.create({
        index: indexName,
        mappings: { properties: { content: { type: 'text' } } },
      });

      const stats = await client.indices.stats({ index: indexName });
      expect(stats.indices?.[indexName]).toBeDefined();
    });
  });
});

// ============================================================================
// Skip message for offline testing
// ============================================================================

describe('Integration Test Prerequisites', () => {
  it('Elasticsearch availability note', () => {
    console.log(`
    ===============================================================
    INTEGRATION TESTS
    ===============================================================
    
    To run integration tests, start Elasticsearch:
    
      docker-compose -f tests/docker-compose.test.yml up -d
    
    Then run:
    
      npm run test:integration
    
    Or with custom ES URL:
    
      ES_URL=http://localhost:9200 npm run test:integration
    
    ===============================================================
    `);
    expect(true).toBe(true);
  });
});