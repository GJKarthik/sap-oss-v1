/**
 * Week 7 Integration Tests
 *
 * End-to-end tests for orchestration integration:
 * - Grounding Module + RAG Chain
 * - Ingest Pipeline + Embedding
 * - Complete RAG pipeline flow
 */

import {
  // Types
  GroundingResult,
  GroundingSource,
  TextChunk,
  EmbeddedDocument,
  PaginatedResults,
  // Grounding
  ElasticsearchGroundingModule,
  ContextBuilder,
  createGroundingModule,
  createContextBuilder,
  PromptTemplates,
  buildPrompt,
  // RAG Chain
  RagChain,
  RagPipelineBuilder,
  createRagChain,
  ragPipeline,
  mergeGroundingResults,
  createReranker,
  createContentFilter,
  // Ingest Pipeline
  IngestPipelineBuilder,
  PipelinePresets,
  ingestPipeline,
  // Embedding Ingest
  TextChunker,
  EmbeddingHelper,
  DocumentProcessor,
  ChunkPresets,
  createChunker,
  createEmbeddingHelper,
  createDocumentProcessor,
  chunkText,
  // Metadata Filter
  metadataFilter,
  FilterPresets,
  // Pagination
  createPaginator,
  calculatePaginationInfo,
  // Hybrid Search
  createHybridSearch,
  HybridSearcher,
  createHybridSearcher,
  // Boost
  BoostBuilder,
  BoostPresets,
} from '../src/index.js';

// ============================================================================
// Mock Helpers
// ============================================================================

/**
 * Create mock grounding result
 */
function createMockGroundingResult(count: number = 5): GroundingResult {
  const sources: GroundingSource[] = [];
  for (let i = 0; i < count; i++) {
    sources.push({
      id: `doc-${i}`,
      content: `This is the content of document ${i}. It contains information about topic ${i % 3}.`,
      score: 1 - (i * 0.1),
      metadata: {
        title: `Document ${i}`,
        source: 'test',
        category: i % 2 === 0 ? 'A' : 'B',
      },
    });
  }
  return {
    sources,
    totalFound: count * 2,
    took: 50,
    query: 'test query',
  };
}

/**
 * Create mock embedding function
 */
function createMockEmbedFn(dimension: number = 1536): (texts: string[]) => Promise<number[][]> {
  return async (texts: string[]): Promise<number[][]> => {
    return texts.map(() => {
      const embedding = new Array(dimension).fill(0);
      for (let i = 0; i < dimension; i++) {
        embedding[i] = Math.random() * 2 - 1;
      }
      // Normalize
      const norm = Math.sqrt(embedding.reduce((sum, v) => sum + v * v, 0));
      return embedding.map((v) => v / norm);
    });
  };
}

/**
 * Create mock ES client
 */
function createMockClient() {
  return {
    search: jest.fn().mockResolvedValue({
      hits: {
        hits: [
          { _id: 'doc-1', _score: 0.9, _source: { content: 'Test content 1', metadata: {} } },
          { _id: 'doc-2', _score: 0.8, _source: { content: 'Test content 2', metadata: {} } },
        ],
        total: { value: 2 },
      },
      took: 10,
    }),
    indices: {
      exists: jest.fn().mockResolvedValue(true),
      putSettings: jest.fn().mockResolvedValue({}),
    },
    ingest: {
      putPipeline: jest.fn().mockResolvedValue({}),
      getPipeline: jest.fn().mockResolvedValue({}),
      deletePipeline: jest.fn().mockResolvedValue({}),
      simulate: jest.fn().mockResolvedValue({ docs: [] }),
    },
    bulk: jest.fn().mockResolvedValue({ items: [], errors: false }),
  };
}

// ============================================================================
// Grounding Module Tests
// ============================================================================

describe('Week 7 Integration: Grounding Module', () => {
  describe('ContextBuilder', () => {
    it('should build context from grounding result', () => {
      const builder = createContextBuilder({
        maxContextLength: 8000,
        separator: '\n\n---\n\n',
        referenceFormat: 'numbered',
      });
      
      const groundingResult = createMockGroundingResult(3);
      const context = builder.build(groundingResult);
      
      expect(context.context).toContain('[1]');
      expect(context.context).toContain('[2]');
      expect(context.context).toContain('[3]');
      expect(context.references).toHaveLength(3);
      expect(context.sourcesUsed).toBe(3);
      expect(context.wasTruncated).toBe(false);
    });

    it('should truncate context when exceeding max length', () => {
      const builder = createContextBuilder({
        maxContextLength: 200,
        separator: '\n',
      });
      
      const groundingResult = createMockGroundingResult(10);
      const context = builder.build(groundingResult);
      
      expect(context.characterCount).toBeLessThanOrEqual(200);
      expect(context.wasTruncated).toBe(true);
      expect(context.sourcesUsed).toBeLessThan(10);
    });

    it('should include footer references when configured', () => {
      const builder = createContextBuilder({
        referenceFormat: 'footer',
        includeReferences: true,
      });
      
      const groundingResult = createMockGroundingResult(2);
      const context = builder.build(groundingResult);
      
      expect(context.context).toContain('References:');
      expect(context.context).toContain('[1]');
      expect(context.context).toContain('[2]');
    });

    it('should include inline references when configured', () => {
      const builder = createContextBuilder({
        referenceFormat: 'inline',
      });
      
      const groundingResult = createMockGroundingResult(2);
      groundingResult.sources[0].metadata = { title: 'Doc A' };
      groundingResult.sources[1].metadata = { title: 'Doc B' };
      
      const context = builder.build(groundingResult);
      
      expect(context.context).toContain('[Doc A]');
      expect(context.context).toContain('[Doc B]');
    });
  });

  describe('PromptTemplates', () => {
    it('should build prompt with default template', () => {
      const groundingResult = createMockGroundingResult(2);
      const contextBuilder = createContextBuilder();
      const context = contextBuilder.build(groundingResult);
      
      const prompt = buildPrompt(PromptTemplates.default, 'What is RAG?', context);
      
      expect(prompt.system).toContain('Context:');
      expect(prompt.system).toContain(context.context);
      expect(prompt.user).toBe('What is RAG?');
    });

    it('should build prompt with technical template', () => {
      const groundingResult = createMockGroundingResult(2);
      const contextBuilder = createContextBuilder();
      const context = contextBuilder.build(groundingResult);
      
      const prompt = buildPrompt(PromptTemplates.technical, 'How does kNN work?', context);
      
      expect(prompt.system).toContain('technical documentation');
      expect(prompt.system).toContain('[1], [2]');
    });

    it('should build prompt with Q&A template', () => {
      const groundingResult = createMockGroundingResult(2);
      const contextBuilder = createContextBuilder();
      const context = contextBuilder.build(groundingResult);
      
      const prompt = buildPrompt(PromptTemplates.qaWithSources, 'Explain hybrid search', context);
      
      expect(prompt.system).toContain('cite your sources');
    });
  });
});

// ============================================================================
// RAG Chain Tests
// ============================================================================

describe('Week 7 Integration: RAG Chain', () => {
  describe('RagChain with Mock Grounding', () => {
    it('should execute query and return result with metrics', async () => {
      const mockClient = createMockClient();
      const grounding = createGroundingModule(mockClient as any, 'test-index', {
        embedFn: createMockEmbedFn(),
      });
      
      const contextBuilder = createContextBuilder();
      const ragChain = createRagChain({
        grounding,
        contextBuilder,
        enableMetrics: true,
      });
      
      const result = await ragChain.query('test query');
      
      expect(result.prompt.system).toBeDefined();
      expect(result.prompt.user).toBe('test query');
      expect(result.metrics.totalTime).toBeGreaterThan(0);
      expect(result.cacheHit).toBe(false);
    });

    it('should cache results when enabled', async () => {
      const mockClient = createMockClient();
      const grounding = createGroundingModule(mockClient as any, 'test-index', {
        embedFn: createMockEmbedFn(),
      });
      
      const ragChain = createRagChain({
        grounding,
        contextBuilder: createContextBuilder(),
        enableCache: true,
        cacheTtl: 60000,
      });
      
      // First query
      const result1 = await ragChain.query('test query');
      expect(result1.cacheHit).toBe(false);
      
      // Second query (same)
      const result2 = await ragChain.query('test query');
      expect(result2.cacheHit).toBe(true);
      
      // Cache stats
      const stats = ragChain.getCacheStats();
      expect(stats.hitRate).toBe(0.5);
    });

    it('should skip cache when requested', async () => {
      const mockClient = createMockClient();
      const grounding = createGroundingModule(mockClient as any, 'test-index', {
        embedFn: createMockEmbedFn(),
      });
      
      const ragChain = createRagChain({
        grounding,
        contextBuilder: createContextBuilder(),
        enableCache: true,
      });
      
      await ragChain.query('test query');
      const result = await ragChain.query('test query', { skipCache: true });
      
      expect(result.cacheHit).toBe(false);
    });
  });

  describe('Batch Query', () => {
    it('should process batch queries', async () => {
      const mockClient = createMockClient();
      const grounding = createGroundingModule(mockClient as any, 'test-index', {
        embedFn: createMockEmbedFn(),
      });
      
      const ragChain = createRagChain({
        grounding,
        contextBuilder: createContextBuilder(),
      });
      
      const results = await ragChain.batchQuery([
        { id: '1', query: 'Query 1' },
        { id: '2', query: 'Query 2' },
        { id: '3', query: 'Query 3' },
      ], { concurrency: 2 });
      
      expect(results).toHaveLength(3);
      expect(results[0].id).toBe('1');
      expect(results[1].id).toBe('2');
      expect(results[2].id).toBe('3');
      expect(results.every(r => r.result !== undefined)).toBe(true);
    });
  });

  describe('Streaming Query', () => {
    it('should stream query results', async () => {
      const mockClient = createMockClient();
      const grounding = createGroundingModule(mockClient as any, 'test-index', {
        embedFn: createMockEmbedFn(),
      });
      
      const ragChain = createRagChain({
        grounding,
        contextBuilder: createContextBuilder(),
      });
      
      const chunks: string[] = [];
      for await (const chunk of ragChain.queryStream('test query')) {
        chunks.push(chunk.type);
        if (chunk.type === 'done') {
          expect(chunk.result).toBeDefined();
        }
      }
      
      expect(chunks).toContain('source');
      expect(chunks).toContain('context');
      expect(chunks).toContain('prompt');
      expect(chunks).toContain('done');
    });
  });

  describe('mergeGroundingResults', () => {
    it('should merge multiple grounding results', () => {
      const result1 = createMockGroundingResult(3);
      const result2 = createMockGroundingResult(3);
      
      const merged = mergeGroundingResults([result1, result2], {
        maxSources: 5,
        deduplicateById: true,
      });
      
      // Should deduplicate by ID
      expect(merged.sources.length).toBeLessThanOrEqual(5);
      expect(merged.totalFound).toBe(12); // 6 + 6
    });

    it('should not deduplicate when disabled', () => {
      const result1 = createMockGroundingResult(2);
      const result2 = createMockGroundingResult(2);
      
      const merged = mergeGroundingResults([result1, result2], {
        maxSources: 10,
        deduplicateById: false,
      });
      
      expect(merged.sources.length).toBe(4);
    });
  });
});

// ============================================================================
// RAG Pipeline Builder Tests
// ============================================================================

describe('Week 7 Integration: RAG Pipeline Builder', () => {
  describe('Pipeline Construction', () => {
    it('should build and execute pipeline', async () => {
      const mockClient = createMockClient();
      const grounding = createGroundingModule(mockClient as any, 'test-index', {
        embedFn: createMockEmbedFn(),
      });
      
      const pipeline = ragPipeline()
        .preprocess('normalize', async (query) => query.toLowerCase().trim())
        .ground(grounding, { topK: 5 })
        .buildContext(createContextBuilder())
        .buildPrompt(PromptTemplates.default)
        .build();
      
      const result = await pipeline.execute('  TEST QUERY  ');
      
      expect(result.totalTime).toBeGreaterThan(0);
      expect(result.context.query).toBe('test query');
    });

    it('should apply filter step', async () => {
      const mockClient = createMockClient();
      const grounding = createGroundingModule(mockClient as any, 'test-index', {
        embedFn: createMockEmbedFn(),
      });
      
      const pipeline = ragPipeline()
        .ground(grounding, { topK: 10 })
        .filter('minLength', createContentFilter((content) => content.length > 10))
        .buildContext(createContextBuilder())
        .build();
      
      const result = await pipeline.execute('test');
      
      expect(result.totalTime).toBeGreaterThan(0);
    });

    it('should apply custom reranker', async () => {
      const mockClient = createMockClient();
      const grounding = createGroundingModule(mockClient as any, 'test-index', {
        embedFn: createMockEmbedFn(),
      });
      
      const mockReranker = createReranker(async (query, sources) => {
        // Reverse the order (simple reranking)
        return [...sources].reverse();
      });
      
      const pipeline = ragPipeline()
        .ground(grounding)
        .rank('rerank', mockReranker)
        .buildContext(createContextBuilder())
        .build();
      
      const result = await pipeline.execute('test');
      
      expect(result.totalTime).toBeGreaterThan(0);
    });
  });

  describe('Pipeline Streaming', () => {
    it('should stream pipeline execution', async () => {
      const mockClient = createMockClient();
      const grounding = createGroundingModule(mockClient as any, 'test-index', {
        embedFn: createMockEmbedFn(),
      });
      
      const pipeline = ragPipeline()
        .ground(grounding)
        .buildContext(createContextBuilder())
        .build();
      
      const steps: string[] = [];
      const stream = pipeline.executeStream('test');
      
      for await (const step of stream) {
        steps.push(step.step);
        expect(step.timing).toBeGreaterThanOrEqual(0);
      }
      
      expect(steps).toContain('ground');
      expect(steps).toContain('buildContext');
    });
  });
});

// ============================================================================
// Ingest Pipeline Tests
// ============================================================================

describe('Week 7 Integration: Ingest Pipeline', () => {
  describe('IngestPipelineBuilder', () => {
    it('should build embedding pipeline', () => {
      const pipeline = ingestPipeline()
        .describe('Test embedding pipeline')
        .set('@timestamp', '{{_ingest.timestamp}}')
        .trim('content')
        .inference('my-model', {
          inputField: 'content',
          outputField: 'embedding',
          inferenceConfig: { text_embedding: {} },
        })
        .build();
      
      expect(pipeline.description).toBe('Test embedding pipeline');
      expect(pipeline.processors).toHaveLength(3);
    });

    it('should use PipelinePresets', () => {
      const textPipeline = PipelinePresets.textProcessing().build();
      expect(textPipeline.processors.length).toBeGreaterThan(0);
      
      const ragPipeline = PipelinePresets.ragDocument('my-model').build();
      expect(ragPipeline.processors.length).toBeGreaterThan(0);
      
      const elserPipeline = PipelinePresets.elserEmbedding().build();
      expect(elserPipeline.processors.length).toBeGreaterThan(0);
    });

    it('should handle conditional processors', () => {
      const pipeline = ingestPipeline()
        .conditionalSet("ctx.category == null", 'category', 'unknown')
        .build();
      
      expect(pipeline.processors[0]).toHaveProperty('if');
    });

    it('should handle on-failure handlers', () => {
      const pipeline = ingestPipeline()
        .set('field', 'value')
        .onFailure({ type: 'set', field: '_error', value: 'failed' })
        .build();
      
      expect(pipeline.onFailure).toHaveLength(1);
    });
  });
});

// ============================================================================
// Text Chunking Tests
// ============================================================================

describe('Week 7 Integration: Text Chunking', () => {
  const sampleText = `
Introduction to RAG

Retrieval-Augmented Generation (RAG) is a technique that combines the power of large language models with external knowledge retrieval.

How RAG Works

RAG works by first retrieving relevant documents from a knowledge base, then using those documents as context for the language model to generate more accurate and informed responses.

Benefits of RAG

1. Improved accuracy
2. Reduced hallucinations
3. Access to up-to-date information
4. Domain-specific knowledge

Conclusion

RAG represents an important advancement in AI technology, enabling more reliable and factual responses from language models.
`.trim();

  describe('TextChunker', () => {
    it('should chunk text with default config', () => {
      const chunker = createChunker();
      const chunks = chunker.chunk(sampleText);
      
      expect(chunks.length).toBeGreaterThan(0);
      expect(chunks[0].index).toBe(0);
      expect(chunks[0].content.length).toBeGreaterThan(0);
    });

    it('should chunk with fixed strategy', () => {
      const chunker = createChunker({
        strategy: 'fixed',
        chunkSize: 100,
        chunkOverlap: 20,
      });
      
      const chunks = chunker.chunk(sampleText);
      
      chunks.forEach((chunk, i) => {
        expect(chunk.index).toBe(i);
        expect(chunk.content.length).toBeLessThanOrEqual(100);
      });
    });

    it('should chunk with sentence strategy', () => {
      const chunker = createChunker({
        strategy: 'sentence',
        chunkSize: 200,
      });
      
      const chunks = chunker.chunk(sampleText);
      
      expect(chunks.length).toBeGreaterThan(0);
    });

    it('should chunk with paragraph strategy', () => {
      const chunker = createChunker({
        strategy: 'paragraph',
        chunkSize: 500,
      });
      
      const chunks = chunker.chunk(sampleText);
      
      expect(chunks.length).toBeGreaterThan(0);
    });

    it('should add metadata when enabled', () => {
      const chunker = createChunker({
        addMetadata: true,
      });
      
      const chunks = chunker.chunk(sampleText);
      
      expect(chunks[0].metadata).toBeDefined();
      expect(chunks[0].metadata?.charCount).toBeGreaterThan(0);
      expect(chunks[0].metadata?.wordCount).toBeGreaterThan(0);
    });

    it('should respect minChunkSize', () => {
      const chunker = createChunker({
        chunkSize: 100,
        minChunkSize: 50,
      });
      
      const chunks = chunker.chunk(sampleText);
      
      chunks.forEach((chunk) => {
        expect(chunk.content.length).toBeGreaterThanOrEqual(50);
      });
    });
  });

  describe('ChunkPresets', () => {
    it('should use small preset', () => {
      const chunks = chunkText(sampleText, ChunkPresets.small);
      expect(chunks.length).toBeGreaterThan(0);
    });

    it('should use medium preset', () => {
      const chunks = chunkText(sampleText, ChunkPresets.medium);
      expect(chunks.length).toBeGreaterThan(0);
    });

    it('should use large preset', () => {
      const chunks = chunkText(sampleText, ChunkPresets.large);
      expect(chunks.length).toBeGreaterThan(0);
    });

    it('should use code preset', () => {
      const codeText = `
class MyClass {
  constructor() {
    this.value = 0;
  }
  
  increment() {
    this.value++;
  }
}

function helper() {
  return new MyClass();
}
`.trim();
      
      const chunks = chunkText(codeText, ChunkPresets.code);
      expect(chunks.length).toBeGreaterThan(0);
    });
  });
});

// ============================================================================
// Embedding Helper Tests
// ============================================================================

describe('Week 7 Integration: Embedding Helper', () => {
  describe('EmbeddingHelper', () => {
    it('should generate embeddings for texts', async () => {
      const helper = createEmbeddingHelper({
        dimension: 384,
        embedFn: createMockEmbedFn(384),
      });
      
      const embeddings = await helper.embed(['text1', 'text2', 'text3']);
      
      expect(embeddings).toHaveLength(3);
      embeddings.forEach((emb) => {
        expect(emb).toHaveLength(384);
      });
    });

    it('should generate single embedding', async () => {
      const helper = createEmbeddingHelper({
        dimension: 384,
        embedFn: createMockEmbedFn(384),
      });
      
      const embedding = await helper.embedSingle('test text');
      
      expect(embedding).toHaveLength(384);
    });

    it('should embed documents with chunking', async () => {
      const helper = createEmbeddingHelper({
        dimension: 384,
        embedFn: createMockEmbedFn(384),
        batchSize: 10,
      });
      
      const docs = [
        { id: 'doc1', content: 'This is a long document that should be chunked. ' + 'x'.repeat(2000) },
        { id: 'doc2', content: 'This is another document.' },
      ];
      
      const embedded = await helper.embedDocuments(docs, {
        chunk: true,
        chunkConfig: ChunkPresets.small,
      });
      
      expect(embedded.length).toBeGreaterThan(2); // doc1 should be chunked
      expect(embedded.some((d) => d.parentId === 'doc1')).toBe(true);
    });
  });

  describe('DocumentProcessor', () => {
    it('should process document with chunking and embedding', async () => {
      const processor = createDocumentProcessor({
        chunkConfig: ChunkPresets.small,
        embeddingConfig: {
          dimension: 384,
          embedFn: createMockEmbedFn(384),
        },
      });
      
      const result = await processor.process(
        { id: 'doc1', content: 'Long content. '.repeat(100), metadata: { source: 'test' } },
        { chunk: true, embed: true }
      );
      
      expect(result.length).toBeGreaterThan(0);
      result.forEach((doc) => {
        expect(doc.embedding.length).toBe(384);
        expect(doc.metadata?.source).toBe('test');
      });
    });

    it('should process multiple documents concurrently', async () => {
      const processor = createDocumentProcessor({
        chunkConfig: ChunkPresets.medium,
        embeddingConfig: {
          dimension: 384,
          embedFn: createMockEmbedFn(384),
        },
      });
      
      const docs = [
        { id: 'doc1', content: 'Content 1. '.repeat(50) },
        { id: 'doc2', content: 'Content 2. '.repeat(50) },
        { id: 'doc3', content: 'Content 3. '.repeat(50) },
      ];
      
      const result = await processor.processMany(docs, {
        chunk: true,
        embed: true,
        concurrency: 2,
      });
      
      expect(result.length).toBeGreaterThan(3);
    });
  });
});

// ============================================================================
// Complete RAG Flow Tests
// ============================================================================

describe('Week 7 Integration: Complete RAG Flow', () => {
  it('should execute complete chunking → embedding → context flow', async () => {
    // 1. Chunk document
    const chunker = createChunker(ChunkPresets.medium);
    const rawText = 'Introduction to AI. '.repeat(100);
    const chunks = chunker.chunk(rawText);
    
    expect(chunks.length).toBeGreaterThan(0);
    
    // 2. Embed chunks
    const embedHelper = createEmbeddingHelper({
      dimension: 384,
      embedFn: createMockEmbedFn(384),
    });
    
    const embeddings = await embedHelper.embed(chunks.map((c) => c.content));
    expect(embeddings.length).toBe(chunks.length);
    
    // 3. Create mock grounding result (simulating search)
    const groundingResult: GroundingResult = {
      sources: chunks.slice(0, 3).map((chunk, i) => ({
        id: `chunk-${i}`,
        content: chunk.content,
        score: 1 - (i * 0.1),
        metadata: {},
      })),
      totalFound: chunks.length,
      took: 10,
      query: 'AI introduction',
    };
    
    // 4. Build context
    const contextBuilder = createContextBuilder({
      maxContextLength: 4000,
      referenceFormat: 'numbered',
    });
    
    const context = contextBuilder.build(groundingResult);
    expect(context.sourcesUsed).toBeLessThanOrEqual(3);
    
    // 5. Build prompt
    const prompt = buildPrompt(PromptTemplates.default, 'What is AI?', context);
    expect(prompt.system).toContain('Context:');
    expect(prompt.user).toBe('What is AI?');
  });

  it('should integrate hybrid search with RAG chain', async () => {
    // Build hybrid search query
    const builder = createHybridSearch()
      .knn('embedding', [], 10)
      .text('content', 'machine learning')
      .withRrf(60)
      .highlight('content');
    
    const query = builder.build();
    
    expect(query.knn).toBeDefined();
    expect(query.query).toBeDefined();
    expect(query.rank).toBeDefined();
  });

  it('should apply metadata filters in RAG pipeline', () => {
    // Build filter
    const filter = metadataFilter()
      .source('docs')
      .category('technical')
      .dateRange('created_at', new Date('2024-01-01'), new Date('2024-12-31'))
      .build();
    
    expect(filter.bool.must).toBeDefined();
  });

  it('should use boost presets for relevance tuning', () => {
    const boost = BoostPresets.recency()
      .field('title', 2)
      .field('content', 1)
      .build();
    
    expect(boost.fieldBoosts).toBeDefined();
    expect(boost.temporalBoosts).toBeDefined();
  });
});

// ============================================================================
// Error Handling Tests
// ============================================================================

describe('Week 7 Integration: Error Handling', () => {
  it('should handle empty text chunking', () => {
    const chunker = createChunker();
    
    const chunks = chunker.chunk('');
    expect(chunks).toEqual([]);
    
    const chunks2 = chunker.chunk('   ');
    expect(chunks2).toEqual([]);
  });

  it('should handle missing embed function', async () => {
    const helper = createEmbeddingHelper({
      dimension: 384,
      // No embedFn provided
    });
    
    await expect(helper.embed(['text'])).rejects.toThrow('No embed function provided');
  });

  it('should handle empty grounding result', () => {
    const builder = createContextBuilder();
    
    const result: GroundingResult = {
      sources: [],
      totalFound: 0,
      took: 0,
    };
    
    const context = builder.build(result);
    expect(context.context).toBe('');
    expect(context.sourcesUsed).toBe(0);
  });
});

// ============================================================================
// Performance Tests
// ============================================================================

describe('Week 7 Integration: Performance', () => {
  it('should track RAG chain metrics', async () => {
    const mockClient = createMockClient();
    const grounding = createGroundingModule(mockClient as any, 'test-index', {
      embedFn: createMockEmbedFn(),
    });
    
    const ragChain = createRagChain({
      grounding,
      contextBuilder: createContextBuilder(),
      enableMetrics: true,
    });
    
    await ragChain.query('test 1');
    await ragChain.query('test 2');
    await ragChain.query('test 3');
    
    const metrics = ragChain.getMetrics();
    
    expect(metrics.totalQueries).toBe(3);
    expect(metrics.avgLatency).toBeGreaterThan(0);
  });

  it('should calculate pagination info', () => {
    const info = calculatePaginationInfo(100, 3, 10);
    
    expect(info.totalPages).toBe(10);
    expect(info.hasNextPage).toBe(true);
    expect(info.hasPreviousPage).toBe(true);
    expect(info.startItem).toBe(21);
    expect(info.endItem).toBe(30);
  });
});