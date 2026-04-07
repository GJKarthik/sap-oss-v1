// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * @sap-ai-sdk/elasticsearch - RAG Chain
 *
 * RAG (Retrieval-Augmented Generation) chain for orchestration integration.
 * Provides streaming, batch operations, caching, and metrics.
 */

import type { Client } from '@elastic/elasticsearch';
import type { GroundingResult, GroundingSource } from './types.js';
import { wrapError } from './errors.js';
import type { 
  ElasticsearchGroundingModule, 
  BuiltContext,
  ContextBuilder,
  PromptTemplate,
} from './grounding-module.js';

// ============================================================================
// Types
// ============================================================================

/**
 * RAG chain configuration
 */
export interface RagChainConfig {
  /** Grounding module */
  grounding: ElasticsearchGroundingModule;
  /** Context builder */
  contextBuilder: ContextBuilder;
  /** Default prompt template */
  defaultTemplate?: PromptTemplate;
  /** Enable caching */
  enableCache?: boolean;
  /** Cache TTL in milliseconds */
  cacheTtl?: number;
  /** Maximum cache size */
  maxCacheSize?: number;
  /** Enable metrics */
  enableMetrics?: boolean;
}

/**
 * RAG chain result
 */
export interface RagChainResult {
  /** Built context */
  context: BuiltContext;
  /** Grounding result */
  grounding: GroundingResult;
  /** Generated prompt */
  prompt: { system: string; user: string };
  /** Metrics */
  metrics: RagMetrics;
  /** Cache hit */
  cacheHit: boolean;
}

/**
 * RAG metrics
 */
export interface RagMetrics {
  /** Total time in ms */
  totalTime: number;
  /** Grounding time in ms */
  groundingTime: number;
  /** Context build time in ms */
  contextBuildTime: number;
  /** Number of sources retrieved */
  sourcesRetrieved: number;
  /** Number of sources used */
  sourcesUsed: number;
  /** Context length in chars */
  contextLength: number;
  /** Was context truncated */
  wasTruncated: boolean;
}

/**
 * Streaming chunk
 */
export interface RagStreamChunk {
  /** Chunk type */
  type: 'source' | 'context' | 'prompt' | 'done';
  /** Source (if type is 'source') */
  source?: GroundingSource;
  /** Partial context (if type is 'context') */
  context?: string;
  /** Prompt (if type is 'prompt') */
  prompt?: { system: string; user: string };
  /** Final result (if type is 'done') */
  result?: RagChainResult;
}

/**
 * Batch query item
 */
export interface BatchQueryItem {
  /** Query ID */
  id: string;
  /** Query text */
  query: string;
  /** Optional embedding */
  embedding?: number[];
  /** Query-specific options */
  options?: Partial<RagQueryOptions>;
}

/**
 * Batch result
 */
export interface BatchResult {
  /** Query ID */
  id: string;
  /** Result */
  result?: RagChainResult;
  /** Error if failed */
  error?: Error;
}

/**
 * RAG query options
 */
export interface RagQueryOptions {
  /** Top-K results */
  topK?: number;
  /** Minimum score */
  minScore?: number;
  /** Use hybrid search */
  useHybrid?: boolean;
  /** Metadata filter */
  filter?: Record<string, unknown>;
  /** Custom template */
  template?: PromptTemplate;
  /** Skip cache */
  skipCache?: boolean;
}

/**
 * Cache entry
 */
interface CacheEntry {
  /** Cached result */
  result: RagChainResult;
  /** Timestamp */
  timestamp: number;
  /** Query hash */
  queryHash: string;
}

// ============================================================================
// RAG Chain Class
// ============================================================================

/**
 * RAG chain for orchestration integration
 */
export class RagChain {
  private readonly grounding: ElasticsearchGroundingModule;
  private readonly contextBuilder: ContextBuilder;
  private readonly defaultTemplate: PromptTemplate;
  private readonly enableCache: boolean;
  private readonly cacheTtl: number;
  private readonly maxCacheSize: number;
  private readonly enableMetrics: boolean;
  private readonly cache: Map<string, CacheEntry> = new Map();
  
  // Metrics
  private totalQueries: number = 0;
  private cacheHits: number = 0;
  private totalLatency: number = 0;

  constructor(config: RagChainConfig) {
    this.grounding = config.grounding;
    this.contextBuilder = config.contextBuilder;
    this.defaultTemplate = config.defaultTemplate ?? {
      name: 'default',
      system: 'Answer based on the following context:\n\n{context}',
      user: '{question}',
    };
    this.enableCache = config.enableCache ?? false;
    this.cacheTtl = config.cacheTtl ?? 5 * 60 * 1000; // 5 minutes
    this.maxCacheSize = config.maxCacheSize ?? 100;
    this.enableMetrics = config.enableMetrics ?? true;
  }

  /**
   * Execute RAG query
   */
  async query(
    question: string,
    options: RagQueryOptions = {}
  ): Promise<RagChainResult> {
    const startTime = Date.now();
    this.totalQueries++;

    // Check cache
    if (this.enableCache && !options.skipCache) {
      const cached = this.getCached(question, options);
      if (cached) {
        this.cacheHits++;
        return { ...cached.result, cacheHit: true };
      }
    }

    // Ground query
    const groundingStart = Date.now();
    const groundingResult = await this.grounding.ground(question, {
      topK: options.topK,
      minScore: options.minScore,
      useHybrid: options.useHybrid,
      filter: options.filter,
    });
    const groundingTime = Date.now() - groundingStart;

    // Build context
    const contextStart = Date.now();
    const context = this.contextBuilder.build(groundingResult);
    const contextBuildTime = Date.now() - contextStart;

    // Build prompt
    const template = options.template ?? this.defaultTemplate;
    const prompt = {
      system: template.system.replace('{context}', context.context),
      user: template.user.replace('{question}', question),
    };

    const totalTime = Date.now() - startTime;
    this.totalLatency += totalTime;

    // Build metrics
    const metrics: RagMetrics = {
      totalTime,
      groundingTime,
      contextBuildTime,
      sourcesRetrieved: groundingResult.sources.length,
      sourcesUsed: context.sourcesUsed,
      contextLength: context.characterCount,
      wasTruncated: context.wasTruncated,
    };

    const result: RagChainResult = {
      context,
      grounding: groundingResult,
      prompt,
      metrics,
      cacheHit: false,
    };

    // Cache result
    if (this.enableCache) {
      this.setCached(question, options, result);
    }

    return result;
  }

  /**
   * Execute RAG query with streaming results
   */
  async *queryStream(
    question: string,
    options: RagQueryOptions = {}
  ): AsyncGenerator<RagStreamChunk, void, unknown> {
    const startTime = Date.now();

    // Ground query
    const groundingResult = await this.grounding.ground(question, {
      topK: options.topK,
      minScore: options.minScore,
      useHybrid: options.useHybrid,
      filter: options.filter,
    });

    // Stream sources
    for (const source of groundingResult.sources) {
      yield { type: 'source', source };
    }

    // Build context
    const context = this.contextBuilder.build(groundingResult);
    yield { type: 'context', context: context.context };

    // Build prompt
    const template = options.template ?? this.defaultTemplate;
    const prompt = {
      system: template.system.replace('{context}', context.context),
      user: template.user.replace('{question}', question),
    };
    yield { type: 'prompt', prompt };

    // Final result
    const metrics: RagMetrics = {
      totalTime: Date.now() - startTime,
      groundingTime: groundingResult.took,
      contextBuildTime: 0,
      sourcesRetrieved: groundingResult.sources.length,
      sourcesUsed: context.sourcesUsed,
      contextLength: context.characterCount,
      wasTruncated: context.wasTruncated,
    };

    yield {
      type: 'done',
      result: {
        context,
        grounding: groundingResult,
        prompt,
        metrics,
        cacheHit: false,
      },
    };
  }

  /**
   * Execute batch RAG queries
   */
  async batchQuery(
    queries: BatchQueryItem[],
    options: {
      concurrency?: number;
      stopOnError?: boolean;
    } = {}
  ): Promise<BatchResult[]> {
    const concurrency = options.concurrency ?? 5;
    const stopOnError = options.stopOnError ?? false;

    const results: BatchResult[] = [];
    const chunks: BatchQueryItem[][] = [];

    // Split into chunks for concurrency control
    for (let i = 0; i < queries.length; i += concurrency) {
      chunks.push(queries.slice(i, i + concurrency));
    }

    // Process chunks
    for (const chunk of chunks) {
      const chunkResults = await Promise.allSettled(
        chunk.map(async (item) => {
          const result = await this.query(item.query, item.options);
          return { id: item.id, result };
        })
      );

      for (let i = 0; i < chunkResults.length; i++) {
        const settled = chunkResults[i];
        if (settled.status === 'fulfilled') {
          results.push(settled.value);
        } else {
          const error = settled.reason as Error;
          results.push({ id: chunk[i].id, error });
          if (stopOnError) {
            return results;
          }
        }
      }
    }

    return results;
  }

  /**
   * Query with pre-computed embedding
   */
  async queryWithEmbedding(
    question: string,
    embedding: number[],
    options: RagQueryOptions = {}
  ): Promise<RagChainResult> {
    const startTime = Date.now();

    // Ground with embedding
    const groundingResult = await this.grounding.groundWithEmbedding(embedding, {
      topK: options.topK,
      minScore: options.minScore,
      filter: options.filter,
    });

    // Build context and prompt
    const context = this.contextBuilder.build(groundingResult);
    const template = options.template ?? this.defaultTemplate;
    const prompt = {
      system: template.system.replace('{context}', context.context),
      user: template.user.replace('{question}', question),
    };

    const metrics: RagMetrics = {
      totalTime: Date.now() - startTime,
      groundingTime: groundingResult.took,
      contextBuildTime: 0,
      sourcesRetrieved: groundingResult.sources.length,
      sourcesUsed: context.sourcesUsed,
      contextLength: context.characterCount,
      wasTruncated: context.wasTruncated,
    };

    return {
      context,
      grounding: groundingResult,
      prompt,
      metrics,
      cacheHit: false,
    };
  }

  // ============================================================================
  // Cache Methods
  // ============================================================================

  /**
   * Get cached result
   */
  private getCached(
    question: string,
    options: RagQueryOptions
  ): CacheEntry | undefined {
    const hash = this.hashQuery(question, options);
    const entry = this.cache.get(hash);

    if (!entry) return undefined;

    // Check TTL
    if (Date.now() - entry.timestamp > this.cacheTtl) {
      this.cache.delete(hash);
      return undefined;
    }

    return entry;
  }

  /**
   * Set cached result
   */
  private setCached(
    question: string,
    options: RagQueryOptions,
    result: RagChainResult
  ): void {
    // Evict oldest if at capacity
    if (this.cache.size >= this.maxCacheSize) {
      const oldest = this.findOldestEntry();
      if (oldest) {
        this.cache.delete(oldest);
      }
    }

    const hash = this.hashQuery(question, options);
    this.cache.set(hash, {
      result,
      timestamp: Date.now(),
      queryHash: hash,
    });
  }

  /**
   * Hash query for cache key
   */
  private hashQuery(question: string, options: RagQueryOptions): string {
    const key = JSON.stringify({
      q: question,
      k: options.topK,
      m: options.minScore,
      h: options.useHybrid,
      f: options.filter,
    });
    // Simple hash function
    let hash = 0;
    for (let i = 0; i < key.length; i++) {
      const char = key.charCodeAt(i);
      hash = ((hash << 5) - hash) + char;
      hash = hash & hash;
    }
    return hash.toString(36);
  }

  /**
   * Find oldest cache entry
   */
  private findOldestEntry(): string | undefined {
    let oldest: { key: string; timestamp: number } | undefined;
    
    for (const [key, entry] of this.cache.entries()) {
      if (!oldest || entry.timestamp < oldest.timestamp) {
        oldest = { key, timestamp: entry.timestamp };
      }
    }

    return oldest?.key;
  }

  /**
   * Clear cache
   */
  clearCache(): void {
    this.cache.clear();
  }

  /**
   * Get cache stats
   */
  getCacheStats(): {
    size: number;
    hitRate: number;
    maxSize: number;
    ttl: number;
  } {
    return {
      size: this.cache.size,
      hitRate: this.totalQueries > 0 
        ? this.cacheHits / this.totalQueries 
        : 0,
      maxSize: this.maxCacheSize,
      ttl: this.cacheTtl,
    };
  }

  // ============================================================================
  // Metrics Methods
  // ============================================================================

  /**
   * Get chain metrics
   */
  getMetrics(): {
    totalQueries: number;
    cacheHits: number;
    cacheHitRate: number;
    avgLatency: number;
  } {
    return {
      totalQueries: this.totalQueries,
      cacheHits: this.cacheHits,
      cacheHitRate: this.totalQueries > 0 
        ? this.cacheHits / this.totalQueries 
        : 0,
      avgLatency: this.totalQueries > 0 
        ? this.totalLatency / this.totalQueries 
        : 0,
    };
  }

  /**
   * Reset metrics
   */
  resetMetrics(): void {
    this.totalQueries = 0;
    this.cacheHits = 0;
    this.totalLatency = 0;
  }
}

// ============================================================================
// RAG Pipeline Builder
// ============================================================================

/**
 * Pipeline step types
 */
export type PipelineStepType = 
  | 'preprocess' 
  | 'embed' 
  | 'ground' 
  | 'filter' 
  | 'rank' 
  | 'context' 
  | 'prompt' 
  | 'postprocess';

/**
 * Pipeline step
 */
export interface PipelineStep<TInput, TOutput> {
  /** Step name */
  name: string;
  /** Step type */
  type: PipelineStepType;
  /** Execute step */
  execute: (input: TInput, context: PipelineContext) => Promise<TOutput>;
}

/**
 * Pipeline context (shared state)
 */
export interface PipelineContext {
  /** Original query */
  query: string;
  /** Embedding (if generated) */
  embedding?: number[];
  /** Grounding result */
  grounding?: GroundingResult;
  /** Built context */
  context?: BuiltContext;
  /** Custom data */
  data: Record<string, unknown>;
  /** Step timings */
  timings: Record<string, number>;
}

/**
 * Pipeline result
 */
export interface PipelineResult<T> {
  /** Final output */
  output: T;
  /** Pipeline context */
  context: PipelineContext;
  /** Total time */
  totalTime: number;
}

/**
 * RAG pipeline builder
 */
export class RagPipelineBuilder<TOutput = RagChainResult> {
  private steps: Array<PipelineStep<unknown, unknown>> = [];

  /**
   * Add preprocessing step
   */
  preprocess(
    name: string,
    fn: (query: string, ctx: PipelineContext) => Promise<string>
  ): this {
    this.steps.push({
      name,
      type: 'preprocess',
      execute: async (input, ctx) => {
        ctx.query = await fn(ctx.query, ctx);
        return ctx.query;
      },
    });
    return this;
  }

  /**
   * Add embedding step
   */
  embed(
    name: string,
    embedFn: (query: string) => Promise<number[]>
  ): this {
    this.steps.push({
      name,
      type: 'embed',
      execute: async (input, ctx) => {
        ctx.embedding = await embedFn(ctx.query);
        return ctx.embedding;
      },
    });
    return this;
  }

  /**
   * Add grounding step
   */
  ground(
    grounding: ElasticsearchGroundingModule,
    options?: Omit<RagQueryOptions, 'template'>
  ): this {
    this.steps.push({
      name: 'ground',
      type: 'ground',
      execute: async (input, ctx) => {
        if (ctx.embedding) {
          ctx.grounding = await grounding.groundWithEmbedding(ctx.embedding, options);
        } else {
          ctx.grounding = await grounding.ground(ctx.query, options);
        }
        return ctx.grounding;
      },
    });
    return this;
  }

  /**
   * Add filter step
   */
  filter(
    name: string,
    filterFn: (sources: GroundingSource[], ctx: PipelineContext) => Promise<GroundingSource[]>
  ): this {
    this.steps.push({
      name,
      type: 'filter',
      execute: async (input, ctx) => {
        if (ctx.grounding) {
          ctx.grounding.sources = await filterFn(ctx.grounding.sources, ctx);
        }
        return ctx.grounding?.sources ?? [];
      },
    });
    return this;
  }

  /**
   * Add ranking step
   */
  rank(
    name: string,
    rankFn: (sources: GroundingSource[], ctx: PipelineContext) => Promise<GroundingSource[]>
  ): this {
    this.steps.push({
      name,
      type: 'rank',
      execute: async (input, ctx) => {
        if (ctx.grounding) {
          ctx.grounding.sources = await rankFn(ctx.grounding.sources, ctx);
        }
        return ctx.grounding?.sources ?? [];
      },
    });
    return this;
  }

  /**
   * Add context building step
   */
  buildContext(contextBuilder: ContextBuilder): this {
    this.steps.push({
      name: 'buildContext',
      type: 'context',
      execute: async (input, ctx) => {
        if (ctx.grounding) {
          ctx.context = contextBuilder.build(ctx.grounding);
        }
        return ctx.context;
      },
    });
    return this;
  }

  /**
   * Add prompt building step
   */
  buildPrompt(template: PromptTemplate): this {
    this.steps.push({
      name: 'buildPrompt',
      type: 'prompt',
      execute: async (input, ctx) => {
        if (!ctx.context) return null;
        return {
          system: template.system.replace('{context}', ctx.context.context),
          user: template.user.replace('{question}', ctx.query),
        };
      },
    });
    return this;
  }

  /**
   * Add postprocessing step
   */
  postprocess<T>(
    name: string,
    fn: (ctx: PipelineContext) => Promise<T>
  ): RagPipelineBuilder<T> {
    this.steps.push({
      name,
      type: 'postprocess',
      execute: async (input, ctx) => fn(ctx),
    });
    return this as unknown as RagPipelineBuilder<T>;
  }

  /**
   * Build and return pipeline executor
   */
  build(): RagPipeline<TOutput> {
    return new RagPipeline<TOutput>(this.steps);
  }
}

/**
 * Executable RAG pipeline
 */
export class RagPipeline<TOutput> {
  constructor(
    private readonly steps: Array<PipelineStep<unknown, unknown>>
  ) {}

  /**
   * Execute pipeline
   */
  async execute(query: string): Promise<PipelineResult<TOutput>> {
    const startTime = Date.now();

    const context: PipelineContext = {
      query,
      data: {},
      timings: {},
    };

    let result: unknown = query;

    for (const step of this.steps) {
      const stepStart = Date.now();
      result = await step.execute(result, context);
      context.timings[step.name] = Date.now() - stepStart;
    }

    return {
      output: result as TOutput,
      context,
      totalTime: Date.now() - startTime,
    };
  }

  /**
   * Execute with streaming progress
   */
  async *executeStream(query: string): AsyncGenerator<{
    step: string;
    type: PipelineStepType;
    result: unknown;
    timing: number;
  }, PipelineResult<TOutput>, unknown> {
    const startTime = Date.now();

    const context: PipelineContext = {
      query,
      data: {},
      timings: {},
    };

    let result: unknown = query;

    for (const step of this.steps) {
      const stepStart = Date.now();
      result = await step.execute(result, context);
      const timing = Date.now() - stepStart;
      context.timings[step.name] = timing;

      yield {
        step: step.name,
        type: step.type,
        result,
        timing,
      };
    }

    return {
      output: result as TOutput,
      context,
      totalTime: Date.now() - startTime,
    };
  }
}

// ============================================================================
// Factory Functions
// ============================================================================

/**
 * Create RAG chain
 */
export function createRagChain(config: RagChainConfig): RagChain {
  return new RagChain(config);
}

/**
 * Create RAG pipeline builder
 */
export function ragPipeline(): RagPipelineBuilder<unknown> {
  return new RagPipelineBuilder();
}

/**
 * Create simple RAG chain (convenience)
 */
export function createSimpleRagChain(
  grounding: ElasticsearchGroundingModule,
  options?: {
    maxContextLength?: number;
    template?: PromptTemplate;
    enableCache?: boolean;
  }
): RagChain {
  const { ContextBuilder } = require('./grounding-module.js');
  
  const contextBuilder = new ContextBuilder({
    maxContextLength: options?.maxContextLength ?? 8000,
    referenceFormat: 'numbered',
  });

  return new RagChain({
    grounding,
    contextBuilder,
    defaultTemplate: options?.template,
    enableCache: options?.enableCache ?? false,
  });
}

// ============================================================================
// Utility Functions
// ============================================================================

/**
 * Merge multiple grounding results
 */
export function mergeGroundingResults(
  results: GroundingResult[],
  options?: {
    maxSources?: number;
    deduplicateById?: boolean;
  }
): GroundingResult {
  const maxSources = options?.maxSources ?? 10;
  const deduplicateById = options?.deduplicateById ?? true;

  const allSources: GroundingSource[] = [];
  let totalFound = 0;
  let totalTook = 0;

  for (const result of results) {
    totalFound += result.totalFound;
    totalTook += result.took;

    for (const source of result.sources) {
      if (deduplicateById) {
        const exists = allSources.some((s) => s.id === source.id);
        if (!exists) {
          allSources.push(source);
        }
      } else {
        allSources.push(source);
      }
    }
  }

  // Sort by score and limit
  allSources.sort((a, b) => b.score - a.score);
  const sources = allSources.slice(0, maxSources);

  return {
    sources,
    totalFound,
    took: totalTook,
    query: results[0]?.query,
  };
}

/**
 * Create re-ranker function
 */
export function createReranker(
  rerankFn: (query: string, sources: GroundingSource[]) => Promise<GroundingSource[]>
): (sources: GroundingSource[], ctx: PipelineContext) => Promise<GroundingSource[]> {
  return async (sources, ctx) => rerankFn(ctx.query, sources);
}

/**
 * Create content filter
 */
export function createContentFilter(
  filterFn: (content: string) => boolean
): (sources: GroundingSource[], ctx: PipelineContext) => Promise<GroundingSource[]> {
  return async (sources) => sources.filter((s) => filterFn(s.content));
}

/**
 * Create metadata filter for pipeline
 */
export function createMetadataFilter(
  filterFn: (metadata: Record<string, unknown>) => boolean
): (sources: GroundingSource[], ctx: PipelineContext) => Promise<GroundingSource[]> {
  return async (sources) => sources.filter((s) => filterFn(s.metadata ?? {}));
}