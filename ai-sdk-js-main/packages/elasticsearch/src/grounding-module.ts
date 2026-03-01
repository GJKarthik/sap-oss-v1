// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * @sap-ai-sdk/elasticsearch - Grounding Module
 *
 * Integration adapter for SAP AI SDK orchestration layer.
 * Provides RAG (Retrieval-Augmented Generation) capabilities.
 */

import type { Client } from '@elastic/elasticsearch';
import type { Document, SearchResult, GroundingConfig, GroundingResult, GroundingSource } from './types.js';
import { ElasticsearchError, wrapError } from './errors.js';
import { metadataFilter, type MetadataFilterBuilder } from './metadata-filter.js';
import type { HybridSearchConfig } from './hybrid-search.js';

// ============================================================================
// Interface Definitions (Compatible with ai-sdk orchestration)
// ============================================================================

/**
 * Grounding module interface (compatible with ai-sdk orchestration)
 */
export interface GroundingModule {
  /** Module type identifier */
  readonly type: string;
  /** Module name */
  readonly name: string;
  
  /**
   * Ground a query with relevant documents
   * @param query - User query to ground
   * @param options - Grounding options
   * @returns Grounding result with sources
   */
  ground(query: string, options?: GroundingOptions): Promise<GroundingResult>;
  
  /**
   * Ground with embedding vector directly
   * @param embedding - Query embedding vector
   * @param options - Grounding options
   * @returns Grounding result with sources
   */
  groundWithEmbedding(embedding: number[], options?: GroundingOptions): Promise<GroundingResult>;
  
  /**
   * Check if module is ready
   */
  isReady(): Promise<boolean>;
  
  /**
   * Get module configuration
   */
  getConfig(): GroundingModuleConfig;
}

/**
 * Grounding options for queries
 */
export interface GroundingOptions {
  /** Maximum number of sources to return */
  topK?: number;
  /** Minimum relevance score (0-1) */
  minScore?: number;
  /** Metadata filters */
  filter?: Record<string, unknown> | MetadataFilterBuilder;
  /** Include document content in results */
  includeContent?: boolean;
  /** Include embeddings in results */
  includeEmbeddings?: boolean;
  /** Fields to return */
  sourceFields?: string[];
  /** Use hybrid search (vector + text) */
  useHybrid?: boolean;
  /** Hybrid search configuration */
  hybridConfig?: Partial<HybridSearchConfig>;
  /** Context window size (chars around match) */
  contextWindow?: number;
  /** Deduplicate similar results */
  deduplicate?: boolean;
  /** Deduplication similarity threshold */
  dedupeThreshold?: number;
}

/**
 * Grounding module configuration
 */
export interface GroundingModuleConfig {
  /** Index name */
  indexName: string;
  /** Content field name */
  contentField: string;
  /** Embedding field name */
  embeddingField: string;
  /** Metadata field name */
  metadataField: string;
  /** Default top-k results */
  defaultTopK: number;
  /** Default minimum score */
  defaultMinScore: number;
  /** Embedding dimension */
  embeddingDimension: number;
  /** Embedding function (if provided) */
  hasEmbeddingFunction: boolean;
  /** Hybrid search enabled */
  hybridEnabled: boolean;
}

/**
 * Context builder configuration
 */
export interface ContextBuilderConfig {
  /** Maximum total context length */
  maxContextLength?: number;
  /** Context separator */
  separator?: string;
  /** Include source references */
  includeReferences?: boolean;
  /** Reference format */
  referenceFormat?: 'inline' | 'footer' | 'numbered';
  /** Include metadata in context */
  includeMetadata?: boolean;
  /** Metadata fields to include */
  metadataFields?: string[];
}

/**
 * Built context from grounding results
 */
export interface BuiltContext {
  /** Combined context string */
  context: string;
  /** Source references */
  references: ContextReference[];
  /** Total character count */
  characterCount: number;
  /** Number of sources used */
  sourcesUsed: number;
  /** Truncated flag */
  wasTruncated: boolean;
}

/**
 * Context reference
 */
export interface ContextReference {
  /** Reference ID (1-indexed) */
  id: number;
  /** Document ID */
  documentId: string;
  /** Source title or name */
  title?: string;
  /** Source URL */
  url?: string;
  /** Relevance score */
  score: number;
  /** Metadata */
  metadata?: Record<string, unknown>;
}

// ============================================================================
// Elasticsearch Grounding Module Implementation
// ============================================================================

/**
 * Elasticsearch grounding module for RAG integration
 */
export class ElasticsearchGroundingModule implements GroundingModule {
  readonly type = 'elasticsearch';
  readonly name: string;
  
  private readonly client: Client;
  private readonly config: GroundingModuleConfig;
  private readonly embedFn?: (text: string) => Promise<number[]>;

  constructor(
    client: Client,
    options: {
      indexName: string;
      name?: string;
      contentField?: string;
      embeddingField?: string;
      metadataField?: string;
      defaultTopK?: number;
      defaultMinScore?: number;
      embeddingDimension?: number;
      embedFn?: (text: string) => Promise<number[]>;
      hybridEnabled?: boolean;
    }
  ) {
    this.client = client;
    this.name = options.name ?? `es-grounding-${options.indexName}`;
    this.embedFn = options.embedFn;
    
    this.config = {
      indexName: options.indexName,
      contentField: options.contentField ?? 'content',
      embeddingField: options.embeddingField ?? 'embedding',
      metadataField: options.metadataField ?? 'metadata',
      defaultTopK: options.defaultTopK ?? 5,
      defaultMinScore: options.defaultMinScore ?? 0.0,
      embeddingDimension: options.embeddingDimension ?? 1536,
      hasEmbeddingFunction: !!options.embedFn,
      hybridEnabled: options.hybridEnabled ?? true,
    };
  }

  /**
   * Ground a query with relevant documents
   */
  async ground(query: string, options: GroundingOptions = {}): Promise<GroundingResult> {
    const startTime = Date.now();

    try {
      // Generate embedding if function provided
      let embedding: number[] | undefined;
      
      if (this.embedFn) {
        embedding = await this.embedFn(query);
      }

      if (!embedding && !options.useHybrid) {
        throw new ElasticsearchError(
          'No embedding function provided and hybrid search not enabled. ' +
          'Either provide embedFn in constructor or set useHybrid: true.'
        );
      }

      // Use hybrid search if enabled and no embedding
      if (options.useHybrid || !embedding) {
        return this.groundHybrid(query, embedding, options, startTime);
      }

      // Vector search with embedding
      return this.groundWithEmbedding(embedding, {
        ...options,
        // Include query for text matching in hybrid
      });
    } catch (error) {
      throw wrapError(error, 'Grounding failed');
    }
  }

  /**
   * Ground with embedding vector directly
   */
  async groundWithEmbedding(
    embedding: number[],
    options: GroundingOptions = {}
  ): Promise<GroundingResult> {
    const startTime = Date.now();
    const topK = options.topK ?? this.config.defaultTopK;
    const minScore = options.minScore ?? this.config.defaultMinScore;

    try {
      // Build kNN query
      const knnQuery: Record<string, unknown> = {
        field: this.config.embeddingField,
        query_vector: embedding,
        k: topK * 2, // Fetch more for filtering
        num_candidates: Math.max(100, topK * 10),
      };

      // Add filter if provided
      const filter = this.buildFilter(options.filter);
      if (Object.keys(filter).length > 0) {
        knnQuery.filter = filter;
      }

      // Build source fields
      const sourceFields = this.buildSourceFields(options);

      // Execute search
      const response = await this.client.search({
        index: this.config.indexName,
        knn: knnQuery,
        size: topK,
        _source: sourceFields,
      } as Record<string, unknown>);

      // Transform results
      const sources = this.transformHits(response.hits.hits, options, minScore);
      
      // Deduplicate if requested
      const finalSources = options.deduplicate
        ? this.deduplicateSources(sources, options.dedupeThreshold ?? 0.9)
        : sources;

      return {
        sources: finalSources.slice(0, topK),
        totalFound: typeof response.hits.total === 'number'
          ? response.hits.total
          : response.hits.total?.value ?? 0,
        took: Date.now() - startTime,
        query: undefined, // No text query for vector-only search
      };
    } catch (error) {
      throw wrapError(error, 'Vector grounding failed');
    }
  }

  /**
   * Check if module is ready
   */
  async isReady(): Promise<boolean> {
    try {
      const exists = await this.client.indices.exists({
        index: this.config.indexName,
      });
      return exists === true;
    } catch {
      return false;
    }
  }

  /**
   * Get module configuration
   */
  getConfig(): GroundingModuleConfig {
    return { ...this.config };
  }

  // ============================================================================
  // Private Methods
  // ============================================================================

  /**
   * Hybrid grounding (vector + text search)
   */
  private async groundHybrid(
    query: string,
    embedding: number[] | undefined,
    options: GroundingOptions,
    startTime: number
  ): Promise<GroundingResult> {
    const topK = options.topK ?? this.config.defaultTopK;
    const minScore = options.minScore ?? this.config.defaultMinScore;

    // Build combined query
    const searchRequest: Record<string, unknown> = {
      index: this.config.indexName,
      size: topK,
      _source: this.buildSourceFields(options),
    };

    // Build filter
    const filter = this.buildFilter(options.filter);

    if (embedding) {
      // Hybrid: kNN + text search with RRF
      searchRequest.knn = {
        field: this.config.embeddingField,
        query_vector: embedding,
        k: topK * 2,
        num_candidates: Math.max(100, topK * 10),
        ...(Object.keys(filter).length > 0 && { filter }),
      };

      searchRequest.query = {
        bool: {
          should: [
            {
              multi_match: {
                query,
                fields: [this.config.contentField, `${this.config.metadataField}.title^2`],
                type: 'best_fields',
                fuzziness: 'AUTO',
              },
            },
          ],
          ...(Object.keys(filter).length > 0 && { filter: [filter] }),
        },
      };

      // Use RRF for ranking
      searchRequest.rank = {
        rrf: {
          window_size: Math.max(100, topK * 10),
          rank_constant: options.hybridConfig?.rrfK ?? 60,
        },
      };
    } else {
      // Text-only search
      searchRequest.query = {
        bool: {
          must: [
            {
              multi_match: {
                query,
                fields: [this.config.contentField, `${this.config.metadataField}.title^2`],
                type: 'best_fields',
                fuzziness: 'AUTO',
              },
            },
          ],
          ...(Object.keys(filter).length > 0 && { filter: [filter] }),
        },
      };
    }

    try {
      const response = await this.client.search(searchRequest);

      // Transform results
      const sources = this.transformHits(response.hits.hits, options, minScore);
      
      // Deduplicate if requested
      const finalSources = options.deduplicate
        ? this.deduplicateSources(sources, options.dedupeThreshold ?? 0.9)
        : sources;

      return {
        sources: finalSources.slice(0, topK),
        totalFound: typeof response.hits.total === 'number'
          ? response.hits.total
          : response.hits.total?.value ?? 0,
        took: Date.now() - startTime,
        query,
      };
    } catch (error) {
      throw wrapError(error, 'Hybrid grounding failed');
    }
  }

  /**
   * Build filter from options
   */
  private buildFilter(
    filter?: Record<string, unknown> | MetadataFilterBuilder
  ): Record<string, unknown> {
    if (!filter) {
      return {};
    }

    if (typeof filter === 'object' && 'build' in filter) {
      return (filter as MetadataFilterBuilder).build();
    }

    return filter as Record<string, unknown>;
  }

  /**
   * Build source fields for response
   */
  private buildSourceFields(options: GroundingOptions): string[] | boolean {
    if (options.sourceFields) {
      return options.sourceFields;
    }

    const fields = [this.config.contentField, this.config.metadataField];
    
    if (options.includeEmbeddings) {
      fields.push(this.config.embeddingField);
    }

    return fields;
  }

  /**
   * Transform search hits to grounding sources
   */
  private transformHits(
    hits: unknown[],
    options: GroundingOptions,
    minScore: number
  ): GroundingSource[] {
    return hits
      .map((hit) => {
        const h = hit as Record<string, unknown>;
        const source = h._source as Record<string, unknown>;
        const score = typeof h._score === 'number' ? h._score : 0;

        // Normalize score to 0-1 range (approximate)
        const normalizedScore = Math.min(1, Math.max(0, score / 10));

        if (normalizedScore < minScore) {
          return null;
        }

        const content = options.includeContent !== false
          ? (source?.[this.config.contentField] as string) ?? ''
          : '';

        const metadata = (source?.[this.config.metadataField] as Record<string, unknown>) ?? {};

        return {
          id: h._id as string,
          content: options.contextWindow
            ? this.truncateContent(content, options.contextWindow)
            : content,
          score: normalizedScore,
          metadata,
          ...(options.includeEmbeddings && source?.[this.config.embeddingField] && {
            embedding: source[this.config.embeddingField] as number[],
          }),
        };
      })
      .filter((s): s is GroundingSource => s !== null);
  }

  /**
   * Truncate content to context window
   */
  private truncateContent(content: string, windowSize: number): string {
    if (content.length <= windowSize) {
      return content;
    }
    return content.substring(0, windowSize) + '...';
  }

  /**
   * Deduplicate similar sources
   */
  private deduplicateSources(
    sources: GroundingSource[],
    threshold: number
  ): GroundingSource[] {
    const unique: GroundingSource[] = [];

    for (const source of sources) {
      const isDuplicate = unique.some((existing) =>
        this.calculateTextSimilarity(existing.content, source.content) >= threshold
      );

      if (!isDuplicate) {
        unique.push(source);
      }
    }

    return unique;
  }

  /**
   * Calculate simple text similarity (Jaccard)
   */
  private calculateTextSimilarity(a: string, b: string): number {
    const wordsA = new Set(a.toLowerCase().split(/\s+/));
    const wordsB = new Set(b.toLowerCase().split(/\s+/));

    const intersection = new Set([...wordsA].filter((w) => wordsB.has(w)));
    const union = new Set([...wordsA, ...wordsB]);

    return intersection.size / union.size;
  }
}

// ============================================================================
// Context Builder
// ============================================================================

/**
 * Build context string from grounding results for LLM prompts
 */
export class ContextBuilder {
  private config: Required<ContextBuilderConfig>;

  constructor(config: ContextBuilderConfig = {}) {
    this.config = {
      maxContextLength: config.maxContextLength ?? 8000,
      separator: config.separator ?? '\n\n---\n\n',
      includeReferences: config.includeReferences ?? true,
      referenceFormat: config.referenceFormat ?? 'numbered',
      includeMetadata: config.includeMetadata ?? false,
      metadataFields: config.metadataFields ?? ['title', 'source', 'url'],
    };
  }

  /**
   * Build context from grounding result
   */
  build(result: GroundingResult): BuiltContext {
    const references: ContextReference[] = [];
    const contextParts: string[] = [];
    let totalLength = 0;
    let wasTruncated = false;

    for (let i = 0; i < result.sources.length; i++) {
      const source = result.sources[i];
      
      // Build reference
      const ref: ContextReference = {
        id: i + 1,
        documentId: source.id,
        title: source.metadata?.title as string | undefined,
        url: source.metadata?.url as string | undefined,
        score: source.score,
        metadata: this.config.includeMetadata
          ? this.extractMetadata(source.metadata)
          : undefined,
      };
      references.push(ref);

      // Build context part
      let contextPart = source.content;

      if (this.config.referenceFormat === 'inline') {
        const refText = ref.title ?? `Source ${ref.id}`;
        contextPart = `[${refText}]: ${contextPart}`;
      } else if (this.config.referenceFormat === 'numbered') {
        contextPart = `[${ref.id}] ${contextPart}`;
      }

      // Check length
      const partLength = contextPart.length + this.config.separator.length;
      if (totalLength + partLength > this.config.maxContextLength) {
        wasTruncated = true;
        // Try to fit partial content
        const remaining = this.config.maxContextLength - totalLength - this.config.separator.length;
        if (remaining > 100) {
          contextParts.push(contextPart.substring(0, remaining) + '...');
        }
        break;
      }

      contextParts.push(contextPart);
      totalLength += partLength;
    }

    // Build final context
    let context = contextParts.join(this.config.separator);

    // Add footer references if configured
    if (this.config.includeReferences && this.config.referenceFormat === 'footer') {
      const footer = this.buildReferencesFooter(references);
      if (totalLength + footer.length <= this.config.maxContextLength) {
        context += '\n\n' + footer;
      }
    }

    return {
      context,
      references,
      characterCount: context.length,
      sourcesUsed: contextParts.length,
      wasTruncated,
    };
  }

  /**
   * Extract relevant metadata fields
   */
  private extractMetadata(
    metadata?: Record<string, unknown>
  ): Record<string, unknown> | undefined {
    if (!metadata) return undefined;

    const extracted: Record<string, unknown> = {};
    for (const field of this.config.metadataFields) {
      if (field in metadata) {
        extracted[field] = metadata[field];
      }
    }
    return Object.keys(extracted).length > 0 ? extracted : undefined;
  }

  /**
   * Build references footer
   */
  private buildReferencesFooter(references: ContextReference[]): string {
    const lines = ['References:'];
    
    for (const ref of references) {
      let line = `[${ref.id}]`;
      if (ref.title) {
        line += ` ${ref.title}`;
      }
      if (ref.url) {
        line += ` (${ref.url})`;
      }
      lines.push(line);
    }

    return lines.join('\n');
  }
}

// ============================================================================
// Factory Functions
// ============================================================================

/**
 * Create Elasticsearch grounding module
 */
export function createGroundingModule(
  client: Client,
  indexName: string,
  options?: {
    name?: string;
    contentField?: string;
    embeddingField?: string;
    metadataField?: string;
    defaultTopK?: number;
    defaultMinScore?: number;
    embeddingDimension?: number;
    embedFn?: (text: string) => Promise<number[]>;
    hybridEnabled?: boolean;
  }
): ElasticsearchGroundingModule {
  return new ElasticsearchGroundingModule(client, {
    indexName,
    ...options,
  });
}

/**
 * Create grounding module with SAP AI Core embedding function
 */
export function createGroundingModuleWithAICore(
  client: Client,
  indexName: string,
  aiCoreEmbedFn: (text: string) => Promise<number[]>,
  options?: Omit<Parameters<typeof createGroundingModule>[2], 'embedFn'>
): ElasticsearchGroundingModule {
  return createGroundingModule(client, indexName, {
    ...options,
    embedFn: aiCoreEmbedFn,
  });
}

/**
 * Create a context builder
 */
export function createContextBuilder(
  config?: ContextBuilderConfig
): ContextBuilder {
  return new ContextBuilder(config);
}

// ============================================================================
// Prompt Templates
// ============================================================================

/**
 * Prompt template for RAG
 */
export interface PromptTemplate {
  /** Template name */
  name: string;
  /** System prompt with context placeholder */
  system: string;
  /** User prompt template */
  user: string;
}

/**
 * Built-in prompt templates
 */
export const PromptTemplates = {
  /**
   * Default RAG template
   */
  default: {
    name: 'default',
    system: `You are a helpful assistant. Answer questions based on the following context.
If the answer is not in the context, say you don't have enough information.

Context:
{context}`,
    user: '{question}',
  } as PromptTemplate,

  /**
   * Conversational RAG template
   */
  conversational: {
    name: 'conversational',
    system: `You are a friendly and helpful assistant. Use the provided context to answer questions naturally.
Be conversational but accurate. If you're unsure, acknowledge the uncertainty.

Context:
{context}`,
    user: '{question}',
  } as PromptTemplate,

  /**
   * Technical documentation template
   */
  technical: {
    name: 'technical',
    system: `You are a technical documentation assistant. Answer questions precisely based on the provided documentation.
Use code examples when relevant. Cite sources using [1], [2] notation.

Documentation:
{context}`,
    user: '{question}',
  } as PromptTemplate,

  /**
   * Summarization template
   */
  summarization: {
    name: 'summarization',
    system: `You are a summarization assistant. Provide concise summaries of the following content.

Content:
{context}`,
    user: 'Summarize the key points about: {question}',
  } as PromptTemplate,

  /**
   * Q&A with sources template
   */
  qaWithSources: {
    name: 'qaWithSources',
    system: `You are a question-answering assistant. Answer based only on the provided sources.
Always cite your sources using [1], [2] notation at the end of relevant sentences.

Sources:
{context}`,
    user: '{question}',
  } as PromptTemplate,
};

/**
 * Build prompt from template and grounding result
 */
export function buildPrompt(
  template: PromptTemplate,
  question: string,
  context: BuiltContext
): { system: string; user: string } {
  return {
    system: template.system.replace('{context}', context.context),
    user: template.user.replace('{question}', question),
  };
}