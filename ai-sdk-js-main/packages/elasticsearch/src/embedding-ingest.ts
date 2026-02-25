/**
 * @sap-ai-sdk/elasticsearch - Embedding Ingest
 *
 * Utilities for automatic embedding generation via ingest pipelines,
 * including text chunking, batch embedding, and document preparation.
 */

import type { Client } from '@elastic/elasticsearch';
import { wrapError } from './errors.js';
import { ingestPipeline, createPipelineManager, type IngestPipelineBuilder } from './ingest-pipeline.js';

// ============================================================================
// Types
// ============================================================================

/**
 * Chunking strategy
 */
export type ChunkingStrategy = 
  | 'fixed'           // Fixed character count
  | 'sentence'        // Sentence boundaries
  | 'paragraph'       // Paragraph boundaries
  | 'recursive'       // Recursive splitting
  | 'semantic';       // Semantic chunking (requires embeddings)

/**
 * Chunk configuration
 */
export interface ChunkConfig {
  /** Chunking strategy */
  strategy: ChunkingStrategy;
  /** Maximum chunk size in characters */
  chunkSize: number;
  /** Overlap between chunks */
  chunkOverlap: number;
  /** Minimum chunk size */
  minChunkSize?: number;
  /** Separators for recursive splitting */
  separators?: string[];
  /** Keep separator with chunk */
  keepSeparator?: boolean;
  /** Add chunk metadata */
  addMetadata?: boolean;
}

/**
 * Text chunk
 */
export interface TextChunk {
  /** Chunk content */
  content: string;
  /** Chunk index */
  index: number;
  /** Start position in original text */
  startOffset: number;
  /** End position in original text */
  endOffset: number;
  /** Metadata */
  metadata?: {
    charCount: number;
    wordCount: number;
    sentenceCount?: number;
  };
}

/**
 * Embedding function type
 */
export type EmbedFunction = (texts: string[]) => Promise<number[][]>;

/**
 * Embedding model configuration
 */
export interface EmbeddingModelConfig {
  /** Model ID (for ES inference) */
  modelId?: string;
  /** External embed function */
  embedFn?: EmbedFunction;
  /** Embedding dimension */
  dimension: number;
  /** Maximum tokens per request */
  maxTokens?: number;
  /** Maximum batch size */
  batchSize?: number;
}

/**
 * Embedded document
 */
export interface EmbeddedDocument {
  /** Original document ID */
  id: string;
  /** Chunk index (if chunked) */
  chunkIndex?: number;
  /** Content */
  content: string;
  /** Embedding vector */
  embedding: number[];
  /** Original metadata */
  metadata?: Record<string, unknown>;
  /** Chunk metadata */
  chunkMetadata?: TextChunk['metadata'];
  /** Parent document ID (if chunked) */
  parentId?: string;
}

/**
 * Ingest document configuration
 */
export interface IngestDocumentConfig {
  /** Source field for content */
  contentField?: string;
  /** Target field for embedding */
  embeddingField?: string;
  /** Enable chunking */
  chunk?: boolean;
  /** Chunk configuration */
  chunkConfig?: Partial<ChunkConfig>;
  /** Store chunks as nested docs */
  storeChunksAsNested?: boolean;
  /** Chunk field name */
  chunkField?: string;
}

// ============================================================================
// Text Chunker
// ============================================================================

/**
 * Default chunk configuration
 */
const DEFAULT_CHUNK_CONFIG: ChunkConfig = {
  strategy: 'recursive',
  chunkSize: 1000,
  chunkOverlap: 200,
  minChunkSize: 100,
  separators: ['\n\n', '\n', '. ', ' '],
  keepSeparator: true,
  addMetadata: true,
};

/**
 * Text chunker for document splitting
 */
export class TextChunker {
  private config: ChunkConfig;

  constructor(config: Partial<ChunkConfig> = {}) {
    this.config = { ...DEFAULT_CHUNK_CONFIG, ...config };
  }

  /**
   * Chunk text into smaller pieces
   */
  chunk(text: string): TextChunk[] {
    if (!text || text.trim().length === 0) {
      return [];
    }

    switch (this.config.strategy) {
      case 'fixed':
        return this.chunkFixed(text);
      case 'sentence':
        return this.chunkBySentence(text);
      case 'paragraph':
        return this.chunkByParagraph(text);
      case 'recursive':
        return this.chunkRecursive(text);
      default:
        return this.chunkRecursive(text);
    }
  }

  /**
   * Fixed-size chunking
   */
  private chunkFixed(text: string): TextChunk[] {
    const chunks: TextChunk[] = [];
    const { chunkSize, chunkOverlap, minChunkSize = 0 } = this.config;

    let startOffset = 0;
    let index = 0;

    while (startOffset < text.length) {
      const endOffset = Math.min(startOffset + chunkSize, text.length);
      const content = text.slice(startOffset, endOffset);

      if (content.length >= minChunkSize) {
        chunks.push(this.createChunk(content, index, startOffset, endOffset));
        index++;
      }

      startOffset += chunkSize - chunkOverlap;
      if (startOffset >= text.length) break;
    }

    return chunks;
  }

  /**
   * Sentence-based chunking
   */
  private chunkBySentence(text: string): TextChunk[] {
    const sentences = this.splitIntoSentences(text);
    return this.mergeIntoPara(sentences, text);
  }

  /**
   * Paragraph-based chunking
   */
  private chunkByParagraph(text: string): TextChunk[] {
    const paragraphs = text.split(/\n\s*\n/).filter((p) => p.trim().length > 0);
    return this.mergeIntoPara(paragraphs, text);
  }

  /**
   * Recursive chunking (LangChain-style)
   */
  private chunkRecursive(text: string): TextChunk[] {
    const { chunkSize, chunkOverlap, separators = [], minChunkSize = 0 } = this.config;

    // If text fits in chunk, return as-is
    if (text.length <= chunkSize) {
      if (text.length >= minChunkSize) {
        return [this.createChunk(text.trim(), 0, 0, text.length)];
      }
      return [];
    }

    // Try each separator
    for (const separator of separators) {
      if (!text.includes(separator)) continue;

      const splits = text.split(separator);
      if (splits.length === 1) continue;

      // Merge splits into chunks
      const chunks: TextChunk[] = [];
      let currentChunk = '';
      let currentStart = 0;
      let index = 0;

      for (let i = 0; i < splits.length; i++) {
        const split = splits[i];
        const withSep = this.config.keepSeparator && i < splits.length - 1
          ? split + separator
          : split;

        if (currentChunk.length + withSep.length <= chunkSize) {
          currentChunk += withSep;
        } else {
          // Save current chunk
          if (currentChunk.length >= minChunkSize) {
            chunks.push(this.createChunk(
              currentChunk.trim(),
              index,
              currentStart,
              currentStart + currentChunk.length
            ));
            index++;
          }

          // Start new chunk with overlap
          const overlapText = this.getOverlap(currentChunk, chunkOverlap);
          currentStart = currentStart + currentChunk.length - overlapText.length;
          currentChunk = overlapText + withSep;
        }
      }

      // Add remaining chunk
      if (currentChunk.length >= minChunkSize) {
        chunks.push(this.createChunk(
          currentChunk.trim(),
          index,
          currentStart,
          currentStart + currentChunk.length
        ));
      }

      if (chunks.length > 0) {
        return chunks;
      }
    }

    // Fall back to fixed chunking
    return this.chunkFixed(text);
  }

  /**
   * Create chunk with metadata
   */
  private createChunk(
    content: string,
    index: number,
    startOffset: number,
    endOffset: number
  ): TextChunk {
    const chunk: TextChunk = {
      content,
      index,
      startOffset,
      endOffset,
    };

    if (this.config.addMetadata) {
      chunk.metadata = {
        charCount: content.length,
        wordCount: content.split(/\s+/).filter((w) => w.length > 0).length,
        sentenceCount: this.countSentences(content),
      };
    }

    return chunk;
  }

  /**
   * Split text into sentences
   */
  private splitIntoSentences(text: string): string[] {
    return text.split(/(?<=[.!?])\s+/).filter((s) => s.trim().length > 0);
  }

  /**
   * Count sentences in text
   */
  private countSentences(text: string): number {
    return (text.match(/[.!?]+/g) || []).length || 1;
  }

  /**
   * Get overlap text from end of chunk
   */
  private getOverlap(text: string, overlapSize: number): string {
    if (text.length <= overlapSize) return text;
    
    // Try to break at word boundary
    const overlapStart = text.length - overlapSize;
    const wordBoundary = text.lastIndexOf(' ', overlapStart + 50);
    
    if (wordBoundary > overlapStart - 50) {
      return text.slice(wordBoundary + 1);
    }
    
    return text.slice(overlapStart);
  }

  /**
   * Merge small pieces into chunks
   */
  private mergeIntoPara(pieces: string[], originalText: string): TextChunk[] {
    const { chunkSize, chunkOverlap, minChunkSize = 0 } = this.config;
    const chunks: TextChunk[] = [];
    let currentChunk = '';
    let currentStart = 0;
    let index = 0;
    let position = 0;

    for (const piece of pieces) {
      if (currentChunk.length + piece.length + 1 <= chunkSize) {
        currentChunk += (currentChunk ? '\n\n' : '') + piece;
      } else {
        if (currentChunk.length >= minChunkSize) {
          chunks.push(this.createChunk(currentChunk, index, currentStart, position));
          index++;
        }
        currentStart = position;
        currentChunk = piece;
      }
      position = originalText.indexOf(piece, position) + piece.length;
    }

    if (currentChunk.length >= minChunkSize) {
      chunks.push(this.createChunk(currentChunk, index, currentStart, position));
    }

    return chunks;
  }
}

// ============================================================================
// Embedding Helper
// ============================================================================

/**
 * Embedding helper for batch embedding generation
 */
export class EmbeddingHelper {
  private modelConfig: EmbeddingModelConfig;

  constructor(config: EmbeddingModelConfig) {
    this.modelConfig = {
      batchSize: 32,
      maxTokens: 8192,
      ...config,
    };
  }

  /**
   * Generate embeddings for texts
   */
  async embed(texts: string[]): Promise<number[][]> {
    if (!this.modelConfig.embedFn) {
      throw new Error('No embed function provided. Use ES inference pipeline or provide embedFn.');
    }

    const { batchSize = 32 } = this.modelConfig;
    const embeddings: number[][] = [];

    // Process in batches
    for (let i = 0; i < texts.length; i += batchSize) {
      const batch = texts.slice(i, i + batchSize);
      const batchEmbeddings = await this.modelConfig.embedFn(batch);
      embeddings.push(...batchEmbeddings);
    }

    return embeddings;
  }

  /**
   * Embed single text
   */
  async embedSingle(text: string): Promise<number[]> {
    const embeddings = await this.embed([text]);
    return embeddings[0];
  }

  /**
   * Embed documents with optional chunking
   */
  async embedDocuments(
    documents: Array<{ id: string; content: string; metadata?: Record<string, unknown> }>,
    options?: { chunk?: boolean; chunkConfig?: Partial<ChunkConfig> }
  ): Promise<EmbeddedDocument[]> {
    const chunker = new TextChunker(options?.chunkConfig);
    const toEmbed: Array<{ docId: string; content: string; chunkIndex?: number; metadata?: Record<string, unknown>; chunkMeta?: TextChunk['metadata']; parentId?: string }> = [];

    // Prepare documents/chunks
    for (const doc of documents) {
      if (options?.chunk) {
        const chunks = chunker.chunk(doc.content);
        for (const chunk of chunks) {
          toEmbed.push({
            docId: `${doc.id}_chunk_${chunk.index}`,
            content: chunk.content,
            chunkIndex: chunk.index,
            metadata: doc.metadata,
            chunkMeta: chunk.metadata,
            parentId: doc.id,
          });
        }
      } else {
        toEmbed.push({
          docId: doc.id,
          content: doc.content,
          metadata: doc.metadata,
        });
      }
    }

    // Generate embeddings
    const contents = toEmbed.map((d) => d.content);
    const embeddings = await this.embed(contents);

    // Build result
    return toEmbed.map((doc, i) => ({
      id: doc.docId,
      chunkIndex: doc.chunkIndex,
      content: doc.content,
      embedding: embeddings[i],
      metadata: doc.metadata,
      chunkMetadata: doc.chunkMeta,
      parentId: doc.parentId,
    }));
  }

  /**
   * Get embedding dimension
   */
  getDimension(): number {
    return this.modelConfig.dimension;
  }
}

// ============================================================================
// Embedding Ingest Helper
// ============================================================================

/**
 * Helper for setting up embedding ingest pipelines
 */
export class EmbeddingIngestHelper {
  private readonly client: Client;
  private readonly pipelineManager: ReturnType<typeof createPipelineManager>;

  constructor(client: Client) {
    this.client = client;
    this.pipelineManager = createPipelineManager(client);
  }

  /**
   * Create embedding pipeline using ES ML model
   */
  async createEmbeddingPipeline(
    pipelineName: string,
    modelId: string,
    options?: {
      contentField?: string;
      embeddingField?: string;
      preprocessHtml?: boolean;
      addTimestamp?: boolean;
    }
  ): Promise<void> {
    const contentField = options?.contentField ?? 'content';
    const embeddingField = options?.embeddingField ?? 'embedding';

    const builder = ingestPipeline()
      .describe(`Embedding pipeline using ${modelId}`);

    if (options?.addTimestamp) {
      builder.set('@timestamp', '{{_ingest.timestamp}}');
    }

    if (options?.preprocessHtml) {
      builder.htmlStrip(contentField, `${contentField}_clean`);
      builder.inference(modelId, {
        inputField: `${contentField}_clean`,
        outputField: embeddingField,
        inferenceConfig: { text_embedding: {} },
      });
      builder.remove(`${contentField}_clean`);
    } else {
      builder.inference(modelId, {
        inputField: contentField,
        outputField: embeddingField,
        inferenceConfig: { text_embedding: {} },
      });
    }

    await this.pipelineManager.put(pipelineName, builder);
  }

  /**
   * Create ELSER sparse embedding pipeline
   */
  async createElserPipeline(
    pipelineName: string,
    options?: {
      contentField?: string;
      embeddingField?: string;
      elserModel?: string;
    }
  ): Promise<void> {
    const contentField = options?.contentField ?? 'content';
    const embeddingField = options?.embeddingField ?? 'ml.tokens';
    const elserModel = options?.elserModel ?? '.elser_model_2';

    const builder = ingestPipeline()
      .describe(`ELSER sparse embedding pipeline`)
      .set('@timestamp', '{{_ingest.timestamp}}')
      .inference(elserModel, {
        inputField: contentField,
        outputField: embeddingField,
        inferenceConfig: {
          text_expansion: {
            results_field: 'tokens',
          },
        },
      });

    await this.pipelineManager.put(pipelineName, builder);
  }

  /**
   * Create hybrid embedding pipeline (dense + ELSER)
   */
  async createHybridEmbeddingPipeline(
    pipelineName: string,
    denseModelId: string,
    options?: {
      contentField?: string;
      denseEmbeddingField?: string;
      sparseEmbeddingField?: string;
      elserModel?: string;
    }
  ): Promise<void> {
    const contentField = options?.contentField ?? 'content';
    const denseField = options?.denseEmbeddingField ?? 'embedding';
    const sparseField = options?.sparseEmbeddingField ?? 'ml.tokens';
    const elserModel = options?.elserModel ?? '.elser_model_2';

    const builder = ingestPipeline()
      .describe(`Hybrid embedding pipeline (dense + ELSER)`)
      .set('@timestamp', '{{_ingest.timestamp}}')
      // Dense embedding
      .inference(denseModelId, {
        inputField: contentField,
        outputField: denseField,
        inferenceConfig: { text_embedding: {} },
      })
      // ELSER sparse embedding
      .inference(elserModel, {
        inputField: contentField,
        outputField: sparseField,
        inferenceConfig: {
          text_expansion: {
            results_field: 'tokens',
          },
        },
      });

    await this.pipelineManager.put(pipelineName, builder);
  }

  /**
   * Set default pipeline for index
   */
  async setIndexPipeline(indexName: string, pipelineName: string): Promise<void> {
    try {
      await this.client.indices.putSettings({
        index: indexName,
        body: {
          'index.default_pipeline': pipelineName,
        },
      } as Record<string, unknown>);
    } catch (error) {
      throw wrapError(error, `Failed to set pipeline for index: ${indexName}`);
    }
  }

  /**
   * Remove default pipeline from index
   */
  async removeIndexPipeline(indexName: string): Promise<void> {
    try {
      await this.client.indices.putSettings({
        index: indexName,
        body: {
          'index.default_pipeline': null,
        },
      } as Record<string, unknown>);
    } catch (error) {
      throw wrapError(error, `Failed to remove pipeline from index: ${indexName}`);
    }
  }

  /**
   * Ingest documents with embedding pipeline
   */
  async ingestWithEmbedding(
    indexName: string,
    documents: Array<{ id?: string; content: string; metadata?: Record<string, unknown> }>,
    options?: {
      pipelineName?: string;
      contentField?: string;
      metadataField?: string;
      refresh?: boolean;
    }
  ): Promise<{ successful: number; failed: number; errors: string[] }> {
    const contentField = options?.contentField ?? 'content';
    const metadataField = options?.metadataField ?? 'metadata';

    const operations: unknown[] = [];
    for (const doc of documents) {
      operations.push(
        { index: { _index: indexName, ...(doc.id && { _id: doc.id }), ...(options?.pipelineName && { pipeline: options.pipelineName }) } },
        {
          [contentField]: doc.content,
          ...(doc.metadata && { [metadataField]: doc.metadata }),
        }
      );
    }

    try {
      const response = await this.client.bulk({
        operations,
        refresh: options?.refresh,
      });

      const errors: string[] = [];
      let failed = 0;
      let successful = 0;

      for (const item of response.items) {
        const op = item.index;
        if (op?.error) {
          failed++;
          errors.push(`${op._id}: ${op.error.reason}`);
        } else {
          successful++;
        }
      }

      return { successful, failed, errors };
    } catch (error) {
      throw wrapError(error, 'Failed to ingest documents');
    }
  }
}

// ============================================================================
// Document Processor
// ============================================================================

/**
 * Document processor for chunking and embedding preparation
 */
export class DocumentProcessor {
  private readonly chunker: TextChunker;
  private readonly embeddingHelper?: EmbeddingHelper;

  constructor(options?: {
    chunkConfig?: Partial<ChunkConfig>;
    embeddingConfig?: EmbeddingModelConfig;
  }) {
    this.chunker = new TextChunker(options?.chunkConfig);
    if (options?.embeddingConfig) {
      this.embeddingHelper = new EmbeddingHelper(options.embeddingConfig);
    }
  }

  /**
   * Process document for indexing
   */
  async process(
    document: { id: string; content: string; metadata?: Record<string, unknown> },
    options?: { chunk?: boolean; embed?: boolean }
  ): Promise<EmbeddedDocument[]> {
    const shouldChunk = options?.chunk ?? true;
    const shouldEmbed = options?.embed ?? !!this.embeddingHelper;

    // Chunk if needed
    let chunks: TextChunk[];
    if (shouldChunk) {
      chunks = this.chunker.chunk(document.content);
    } else {
      chunks = [{
        content: document.content,
        index: 0,
        startOffset: 0,
        endOffset: document.content.length,
      }];
    }

    // Embed if needed
    if (shouldEmbed && this.embeddingHelper) {
      const contents = chunks.map((c) => c.content);
      const embeddings = await this.embeddingHelper.embed(contents);

      return chunks.map((chunk, i) => ({
        id: shouldChunk ? `${document.id}_${chunk.index}` : document.id,
        chunkIndex: shouldChunk ? chunk.index : undefined,
        content: chunk.content,
        embedding: embeddings[i],
        metadata: document.metadata,
        chunkMetadata: chunk.metadata,
        parentId: shouldChunk ? document.id : undefined,
      }));
    }

    // Return without embeddings (for ES inference pipeline)
    return chunks.map((chunk) => ({
      id: shouldChunk ? `${document.id}_${chunk.index}` : document.id,
      chunkIndex: shouldChunk ? chunk.index : undefined,
      content: chunk.content,
      embedding: [], // Will be filled by ES pipeline
      metadata: document.metadata,
      chunkMetadata: chunk.metadata,
      parentId: shouldChunk ? document.id : undefined,
    }));
  }

  /**
   * Process multiple documents
   */
  async processMany(
    documents: Array<{ id: string; content: string; metadata?: Record<string, unknown> }>,
    options?: { chunk?: boolean; embed?: boolean; concurrency?: number }
  ): Promise<EmbeddedDocument[]> {
    const concurrency = options?.concurrency ?? 5;
    const results: EmbeddedDocument[] = [];

    // Process in batches
    for (let i = 0; i < documents.length; i += concurrency) {
      const batch = documents.slice(i, i + concurrency);
      const batchResults = await Promise.all(
        batch.map((doc) => this.process(doc, options))
      );
      for (const r of batchResults) {
        results.push(...r);
      }
    }

    return results;
  }
}

// ============================================================================
// Factory Functions
// ============================================================================

/**
 * Create text chunker
 */
export function createChunker(config?: Partial<ChunkConfig>): TextChunker {
  return new TextChunker(config);
}

/**
 * Create embedding helper
 */
export function createEmbeddingHelper(config: EmbeddingModelConfig): EmbeddingHelper {
  return new EmbeddingHelper(config);
}

/**
 * Create embedding ingest helper
 */
export function createEmbeddingIngestHelper(client: Client): EmbeddingIngestHelper {
  return new EmbeddingIngestHelper(client);
}

/**
 * Create document processor
 */
export function createDocumentProcessor(options?: {
  chunkConfig?: Partial<ChunkConfig>;
  embeddingConfig?: EmbeddingModelConfig;
}): DocumentProcessor {
  return new DocumentProcessor(options);
}

// ============================================================================
// Preset Configurations
// ============================================================================

/**
 * Preset chunking configurations
 */
export const ChunkPresets = {
  /** Small chunks for precise retrieval */
  small: {
    strategy: 'recursive' as ChunkingStrategy,
    chunkSize: 500,
    chunkOverlap: 100,
    minChunkSize: 50,
  },

  /** Medium chunks (default) */
  medium: {
    strategy: 'recursive' as ChunkingStrategy,
    chunkSize: 1000,
    chunkOverlap: 200,
    minChunkSize: 100,
  },

  /** Large chunks for context */
  large: {
    strategy: 'recursive' as ChunkingStrategy,
    chunkSize: 2000,
    chunkOverlap: 400,
    minChunkSize: 200,
  },

  /** Sentence-based chunking */
  sentence: {
    strategy: 'sentence' as ChunkingStrategy,
    chunkSize: 1000,
    chunkOverlap: 0,
    minChunkSize: 50,
  },

  /** Paragraph-based chunking */
  paragraph: {
    strategy: 'paragraph' as ChunkingStrategy,
    chunkSize: 2000,
    chunkOverlap: 0,
    minChunkSize: 100,
  },

  /** Code-optimized chunking */
  code: {
    strategy: 'recursive' as ChunkingStrategy,
    chunkSize: 1500,
    chunkOverlap: 100,
    minChunkSize: 50,
    separators: ['\n\nclass ', '\n\nfunction ', '\n\ndef ', '\n\n', '\n', ' '],
  },
};

/**
 * Quick chunk function
 */
export function chunkText(text: string, config?: Partial<ChunkConfig>): TextChunk[] {
  return new TextChunker(config).chunk(text);
}