// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * @sap-ai-sdk/elasticsearch - Hybrid Search
 *
 * Advanced search capabilities combining vector (kNN) and BM25 search.
 */

import { Client } from '@elastic/elasticsearch';
import type {
  ElasticsearchConfig,
  SearchResult,
  RetrieveOptions,
  HybridSearchOptions,
} from './types.js';
import { wrapError } from './errors.js';
import { validateEmbedding, validateRetrieveOptions } from './validation.js';

// ============================================================================
// Types
// ============================================================================

/**
 * Options for kNN retrieval
 */
export interface KnnRetrieveOptions extends RetrieveOptions {
  /** Fields to include in _source */
  includeFields?: string[];
  /** Fields to exclude from _source */
  excludeFields?: string[];
  /** Boost factor for kNN query */
  boost?: number;
  /** Similarity threshold (alternative to minScore) */
  similarityThreshold?: number;
}

/**
 * Advanced hybrid search options
 */
export interface AdvancedHybridOptions extends HybridSearchOptions {
  /** Enable debug mode (returns explain info) */
  debug?: boolean;
  /** Custom script score function */
  scriptScore?: {
    source: string;
    params?: Record<string, unknown>;
  };
  /** Rescore configuration */
  rescore?: {
    windowSize: number;
    queryWeight?: number;
    rescoreQueryWeight?: number;
  };
  /** Track total hits (true, false, or number) */
  trackTotalHits?: boolean | number;
  /** Minimum should match for BM25 query */
  minimumShouldMatch?: string | number;
}

/**
 * Enhanced search result with additional metadata
 */
export interface EnhancedSearchResult extends SearchResult {
  /** Vector similarity score (if available) */
  vectorScore?: number;
  /** BM25 score (if available) */
  textScore?: number;
  /** Combined score explanation */
  explanation?: string;
  /** Highlighting matches */
  highlights?: Record<string, string[]>;
  /** Inner hits (for nested queries) */
  innerHits?: Record<string, unknown[]>;
}

/**
 * Search response with aggregations
 */
export interface HybridSearchResponse {
  /** Search results */
  results: EnhancedSearchResult[];
  /** Total hits */
  total: number;
  /** Maximum score */
  maxScore: number | null;
  /** Time taken in milliseconds */
  took: number;
  /** Aggregation results */
  aggregations?: Record<string, unknown>;
  /** Suggest results */
  suggest?: Record<string, unknown[]>;
}

// ============================================================================
// HybridSearchBuilder Class
// ============================================================================

/**
 * Fluent builder for hybrid search queries
 */
export class HybridSearchBuilder {
  private readonly client: Client;
  private readonly indexName: string;
  private readonly embeddingField: string;
  private readonly contentField: string;
  private readonly metadataField: string;
  private readonly embeddingDims: number;

  // Query components
  private knnQuery?: {
    vector: number[];
    k: number;
    numCandidates: number;
    boost: number;
    filter?: Record<string, unknown>;
  };
  private textQuery?: {
    query: string;
    boost: number;
    operator?: 'or' | 'and';
    fuzziness?: string | number;
  };
  private filters: Array<Record<string, unknown>> = [];
  private mustQueries: Array<Record<string, unknown>> = [];
  private shouldQueries: Array<Record<string, unknown>> = [];
  private mustNotQueries: Array<Record<string, unknown>> = [];

  // Options
  private size: number = 10;
  private from: number = 0;
  private minScoreValue?: number;
  private sortFields: Array<Record<string, unknown>> = [];
  private sourceIncludes: string[] = [];
  private sourceExcludes: string[] = [];
  private highlightFields: Record<string, unknown> = {};
  private aggregations: Record<string, unknown> = {};
  private trackTotalHitsValue: boolean | number = true;
  private explainEnabled: boolean = false;

  constructor(
    client: Client,
    config: {
      indexName: string;
      embeddingField?: string;
      contentField?: string;
      metadataField?: string;
      embeddingDims: number;
    }
  ) {
    this.client = client;
    this.indexName = config.indexName;
    this.embeddingField = config.embeddingField ?? 'embedding';
    this.contentField = config.contentField ?? 'content';
    this.metadataField = config.metadataField ?? 'metadata';
    this.embeddingDims = config.embeddingDims;
  }

  // ============================================================================
  // Vector Search
  // ============================================================================

  /**
   * Add kNN vector search
   */
  knn(
    vector: number[],
    options: {
      k?: number;
      numCandidates?: number;
      boost?: number;
      filter?: Record<string, unknown>;
    } = {}
  ): this {
    validateEmbedding(vector, this.embeddingDims);

    this.knnQuery = {
      vector,
      k: options.k ?? 10,
      numCandidates: options.numCandidates ?? (options.k ?? 10) * 2,
      boost: options.boost ?? 1.0,
      filter: options.filter,
    };

    return this;
  }

  /**
   * Add kNN with similarity threshold
   */
  knnWithThreshold(
    vector: number[],
    threshold: number,
    options: {
      k?: number;
      numCandidates?: number;
      boost?: number;
    } = {}
  ): this {
    this.knn(vector, options);
    this.minScore(threshold);
    return this;
  }

  // ============================================================================
  // Text Search
  // ============================================================================

  /**
   * Add BM25 text search
   */
  text(
    query: string,
    options: {
      boost?: number;
      operator?: 'or' | 'and';
      fuzziness?: string | number;
    } = {}
  ): this {
    this.textQuery = {
      query,
      boost: options.boost ?? 1.0,
      operator: options.operator ?? 'or',
      fuzziness: options.fuzziness,
    };

    return this;
  }

  /**
   * Add multi-match text search across multiple fields
   */
  multiMatch(
    query: string,
    fields: string[],
    options: {
      boost?: number;
      type?: 'best_fields' | 'most_fields' | 'cross_fields' | 'phrase' | 'phrase_prefix';
      operator?: 'or' | 'and';
      fuzziness?: string | number;
      tieBreaker?: number;
    } = {}
  ): this {
    this.mustQueries.push({
      multi_match: {
        query,
        fields,
        type: options.type ?? 'best_fields',
        operator: options.operator ?? 'or',
        fuzziness: options.fuzziness,
        tie_breaker: options.tieBreaker,
        boost: options.boost ?? 1.0,
      },
    });

    return this;
  }

  /**
   * Add phrase match
   */
  phrase(query: string, slop: number = 0): this {
    this.mustQueries.push({
      match_phrase: {
        [this.contentField]: {
          query,
          slop,
        },
      },
    });

    return this;
  }

  // ============================================================================
  // Filters
  // ============================================================================

  /**
   * Add a filter clause
   */
  filter(clause: Record<string, unknown>): this {
    this.filters.push(clause);
    return this;
  }

  /**
   * Add term filter
   */
  term(field: string, value: string | number | boolean): this {
    this.filters.push({
      term: { [field]: value },
    });
    return this;
  }

  /**
   * Add terms filter (match any)
   */
  terms(field: string, values: Array<string | number | boolean>): this {
    this.filters.push({
      terms: { [field]: values },
    });
    return this;
  }

  /**
   * Add range filter
   */
  range(
    field: string,
    options: {
      gte?: number | string;
      gt?: number | string;
      lte?: number | string;
      lt?: number | string;
    }
  ): this {
    this.filters.push({
      range: { [field]: options },
    });
    return this;
  }

  /**
   * Add exists filter
   */
  exists(field: string): this {
    this.filters.push({
      exists: { field },
    });
    return this;
  }

  /**
   * Add prefix filter
   */
  prefix(field: string, value: string): this {
    this.filters.push({
      prefix: { [field]: value },
    });
    return this;
  }

  /**
   * Add wildcard filter
   */
  wildcard(field: string, pattern: string): this {
    this.filters.push({
      wildcard: { [field]: pattern },
    });
    return this;
  }

  /**
   * Add metadata filter
   */
  metadata(key: string, value: unknown): this {
    return this.term(`${this.metadataField}.${key}`, value as string | number | boolean);
  }

  /**
   * Add metadata range filter
   */
  metadataRange(
    key: string,
    options: {
      gte?: number | string;
      gt?: number | string;
      lte?: number | string;
      lt?: number | string;
    }
  ): this {
    return this.range(`${this.metadataField}.${key}`, options);
  }

  // ============================================================================
  // Boolean Queries
  // ============================================================================

  /**
   * Add must clause
   */
  must(clause: Record<string, unknown>): this {
    this.mustQueries.push(clause);
    return this;
  }

  /**
   * Add should clause
   */
  should(clause: Record<string, unknown>): this {
    this.shouldQueries.push(clause);
    return this;
  }

  /**
   * Add must_not clause
   */
  mustNot(clause: Record<string, unknown>): this {
    this.mustNotQueries.push(clause);
    return this;
  }

  // ============================================================================
  // Pagination & Sorting
  // ============================================================================

  /**
   * Set result limit
   */
  limit(size: number): this {
    this.size = size;
    return this;
  }

  /**
   * Set offset for pagination
   */
  offset(from: number): this {
    this.from = from;
    return this;
  }

  /**
   * Set minimum score
   */
  minScore(score: number): this {
    this.minScoreValue = score;
    return this;
  }

  /**
   * Add sort field
   */
  sort(field: string, order: 'asc' | 'desc' = 'desc'): this {
    this.sortFields.push({ [field]: { order } });
    return this;
  }

  /**
   * Sort by score
   */
  sortByScore(): this {
    this.sortFields.push({ _score: { order: 'desc' } });
    return this;
  }

  /**
   * Sort by date
   */
  sortByDate(field: string = 'indexed_at', order: 'asc' | 'desc' = 'desc'): this {
    return this.sort(field, order);
  }

  // ============================================================================
  // Source Control
  // ============================================================================

  /**
   * Include specific fields in results
   */
  include(...fields: string[]): this {
    this.sourceIncludes.push(...fields);
    return this;
  }

  /**
   * Exclude specific fields from results
   */
  exclude(...fields: string[]): this {
    this.sourceExcludes.push(...fields);
    return this;
  }

  /**
   * Exclude embedding from results (convenience method)
   */
  excludeEmbedding(): this {
    return this.exclude(this.embeddingField);
  }

  /**
   * Include embedding in results (convenience method)
   */
  includeEmbedding(): this {
    // Remove from excludes if present
    const idx = this.sourceExcludes.indexOf(this.embeddingField);
    if (idx >= 0) {
      this.sourceExcludes.splice(idx, 1);
    }
    return this.include(this.embeddingField);
  }

  // ============================================================================
  // Highlighting
  // ============================================================================

  /**
   * Enable highlighting for a field
   */
  highlight(
    field: string,
    options: {
      preTags?: string[];
      postTags?: string[];
      fragmentSize?: number;
      numberOfFragments?: number;
    } = {}
  ): this {
    this.highlightFields[field] = {
      pre_tags: options.preTags ?? ['<em>'],
      post_tags: options.postTags ?? ['</em>'],
      fragment_size: options.fragmentSize ?? 150,
      number_of_fragments: options.numberOfFragments ?? 3,
    };
    return this;
  }

  /**
   * Enable content highlighting
   */
  highlightContent(options: {
    preTags?: string[];
    postTags?: string[];
    fragmentSize?: number;
    numberOfFragments?: number;
  } = {}): this {
    return this.highlight(this.contentField, options);
  }

  // ============================================================================
  // Aggregations
  // ============================================================================

  /**
   * Add aggregation
   */
  agg(name: string, aggregation: Record<string, unknown>): this {
    this.aggregations[name] = aggregation;
    return this;
  }

  /**
   * Add terms aggregation
   */
  termsAgg(name: string, field: string, size: number = 10): this {
    return this.agg(name, {
      terms: { field, size },
    });
  }

  /**
   * Add date histogram aggregation
   */
  dateHistogram(
    name: string,
    field: string,
    interval: string
  ): this {
    return this.agg(name, {
      date_histogram: {
        field,
        calendar_interval: interval,
      },
    });
  }

  /**
   * Add stats aggregation
   */
  statsAgg(name: string, field: string): this {
    return this.agg(name, {
      stats: { field },
    });
  }

  // ============================================================================
  // Options
  // ============================================================================

  /**
   * Track total hits
   */
  trackTotalHits(value: boolean | number = true): this {
    this.trackTotalHitsValue = value;
    return this;
  }

  /**
   * Enable explain mode
   */
  explain(enabled: boolean = true): this {
    this.explainEnabled = enabled;
    return this;
  }

  // ============================================================================
  // Build & Execute
  // ============================================================================

  /**
   * Build the search request body
   */
  build(): Record<string, unknown> {
    const request: Record<string, unknown> = {
      index: this.indexName,
      size: this.size,
      from: this.from,
      track_total_hits: this.trackTotalHitsValue,
    };

    // Add kNN query
    if (this.knnQuery) {
      request.knn = {
        field: this.embeddingField,
        query_vector: this.knnQuery.vector,
        k: this.knnQuery.k,
        num_candidates: this.knnQuery.numCandidates,
        boost: this.knnQuery.boost,
      };

      if (this.knnQuery.filter) {
        (request.knn as Record<string, unknown>).filter = this.knnQuery.filter;
      }
    }

    // Build bool query
    const boolQuery: Record<string, unknown> = {};

    // Add text query to must
    if (this.textQuery) {
      const matchQuery: Record<string, unknown> = {
        query: this.textQuery.query,
        boost: this.textQuery.boost,
        operator: this.textQuery.operator,
      };

      if (this.textQuery.fuzziness !== undefined) {
        matchQuery.fuzziness = this.textQuery.fuzziness;
      }

      this.mustQueries.push({
        match: { [this.contentField]: matchQuery },
      });
    }

    if (this.mustQueries.length > 0) {
      boolQuery.must = this.mustQueries;
    }

    if (this.shouldQueries.length > 0) {
      boolQuery.should = this.shouldQueries;
    }

    if (this.mustNotQueries.length > 0) {
      boolQuery.must_not = this.mustNotQueries;
    }

    if (this.filters.length > 0) {
      boolQuery.filter = this.filters;
    }

    // Only add query if we have bool clauses
    if (Object.keys(boolQuery).length > 0) {
      request.query = { bool: boolQuery };
    }

    // Add min_score
    if (this.minScoreValue !== undefined) {
      request.min_score = this.minScoreValue;
    }

    // Add sort
    if (this.sortFields.length > 0) {
      request.sort = this.sortFields;
    }

    // Add _source configuration
    if (this.sourceIncludes.length > 0 || this.sourceExcludes.length > 0) {
      request._source = {};
      if (this.sourceIncludes.length > 0) {
        (request._source as Record<string, unknown>).includes = this.sourceIncludes;
      }
      if (this.sourceExcludes.length > 0) {
        (request._source as Record<string, unknown>).excludes = this.sourceExcludes;
      }
    }

    // Add highlighting
    if (Object.keys(this.highlightFields).length > 0) {
      request.highlight = { fields: this.highlightFields };
    }

    // Add aggregations
    if (Object.keys(this.aggregations).length > 0) {
      request.aggs = this.aggregations;
    }

    // Add explain
    if (this.explainEnabled) {
      request.explain = true;
    }

    return request;
  }

  /**
   * Execute the search
   */
  async execute(): Promise<HybridSearchResponse> {
    const request = this.build();

    try {
      const response = await this.client.search(request);

      const results = this.transformHits(response.hits.hits);

      return {
        results,
        total:
          typeof response.hits.total === 'number'
            ? response.hits.total
            : response.hits.total?.value ?? 0,
        maxScore: response.hits.max_score ?? null,
        took: response.took,
        aggregations: response.aggregations as Record<string, unknown> | undefined,
        suggest: response.suggest as Record<string, unknown[]> | undefined,
      };
    } catch (error) {
      throw wrapError(error, 'Hybrid search failed');
    }
  }

  /**
   * Transform search hits to results
   */
  private transformHits(
    hits: Array<{
      _id?: string;
      _score?: number | null;
      _source?: unknown;
      highlight?: Record<string, string[]>;
      _explanation?: unknown;
    }>
  ): EnhancedSearchResult[] {
    return hits.map((hit) => {
      const source = hit._source as Record<string, unknown>;

      const result: EnhancedSearchResult = {
        id: hit._id ?? '',
        score: hit._score ?? 0,
        content: source[this.contentField] as string,
        metadata: source[this.metadataField] as Record<string, unknown>,
      };

      // Add embedding if present
      if (source[this.embeddingField]) {
        result.embedding = source[this.embeddingField] as number[];
      }

      // Add highlights
      if (hit.highlight) {
        result.highlights = hit.highlight;
      }

      // Add explanation
      if (hit._explanation) {
        result.explanation = JSON.stringify(hit._explanation);
      }

      return result;
    });
  }
}

// ============================================================================
// Factory Functions
// ============================================================================

/**
 * Create a hybrid search builder
 */
export function createHybridSearch(
  client: Client,
  config: {
    indexName: string;
    embeddingField?: string;
    contentField?: string;
    metadataField?: string;
    embeddingDims: number;
  }
): HybridSearchBuilder {
  return new HybridSearchBuilder(client, config);
}

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Perform a quick kNN search
 */
export async function quickKnnSearch(
  client: Client,
  indexName: string,
  embeddingField: string,
  vector: number[],
  options: {
    k?: number;
    minScore?: number;
    filter?: Record<string, unknown>;
    sourceExcludes?: string[];
  } = {}
): Promise<SearchResult[]> {
  const {
    k = 10,
    minScore,
    filter,
    sourceExcludes = [embeddingField],
  } = options;

  const request: Record<string, unknown> = {
    index: indexName,
    knn: {
      field: embeddingField,
      query_vector: vector,
      k,
      num_candidates: k * 2,
    },
    _source: {
      excludes: sourceExcludes,
    },
  };

  if (filter) {
    (request.knn as Record<string, unknown>).filter = filter;
  }

  if (minScore !== undefined) {
    request.min_score = minScore;
  }

  try {
    const response = await client.search(request);

    return response.hits.hits.map((hit) => {
      const source = hit._source as Record<string, unknown>;
      return {
        id: hit._id ?? '',
        score: hit._score ?? 0,
        content: source.content as string,
        metadata: source.metadata as Record<string, unknown>,
      };
    });
  } catch (error) {
    throw wrapError(error, 'Quick kNN search failed');
  }
}

/**
 * Perform a quick text search
 */
export async function quickTextSearch(
  client: Client,
  indexName: string,
  contentField: string,
  query: string,
  options: {
    size?: number;
    filter?: Record<string, unknown>;
    sourceExcludes?: string[];
  } = {}
): Promise<SearchResult[]> {
  const {
    size = 10,
    filter,
    sourceExcludes = [],
  } = options;

  const searchQuery: Record<string, unknown> = {
    bool: {
      must: [{ match: { [contentField]: query } }],
    },
  };

  if (filter) {
    (searchQuery.bool as Record<string, unknown>).filter = filter;
  }

  try {
    const response = await client.search({
      index: indexName,
      size,
      query: searchQuery,
      _source: {
        excludes: sourceExcludes,
      },
    });

    return response.hits.hits.map((hit) => {
      const source = hit._source as Record<string, unknown>;
      return {
        id: hit._id ?? '',
        score: hit._score ?? 0,
        content: source.content as string,
        metadata: source.metadata as Record<string, unknown>,
      };
    });
  } catch (error) {
    throw wrapError(error, 'Quick text search failed');
  }
}

/**
 * Calculate Reciprocal Rank Fusion (RRF) score
 */
export function calculateRrfScore(ranks: number[], k: number = 60): number {
  return ranks.reduce((sum, rank) => sum + 1 / (k + rank), 0);
}

/**
 * Merge and re-rank results from multiple searches using RRF
 */
export function mergeResultsWithRrf(
  resultSets: SearchResult[][],
  options: {
    k?: number;
    topK?: number;
  } = {}
): SearchResult[] {
  const { k = 60, topK = 10 } = options;

  // Build a map of document ID to ranks
  const docRanks = new Map<string, { ranks: number[]; result: SearchResult }>();

  for (let setIndex = 0; setIndex < resultSets.length; setIndex++) {
    const results = resultSets[setIndex];
    for (let rank = 0; rank < results.length; rank++) {
      const result = results[rank];
      const existing = docRanks.get(result.id);

      if (existing) {
        existing.ranks[setIndex] = rank + 1;
      } else {
        const ranks = new Array(resultSets.length).fill(1000); // Default high rank
        ranks[setIndex] = rank + 1;
        docRanks.set(result.id, { ranks, result });
      }
    }
  }

  // Calculate RRF scores and sort
  const scoredResults: Array<{ result: SearchResult; rrfScore: number }> = [];

  for (const { ranks, result } of docRanks.values()) {
    const rrfScore = calculateRrfScore(ranks, k);
    scoredResults.push({
      result: { ...result, score: rrfScore },
      rrfScore,
    });
  }

  scoredResults.sort((a, b) => b.rrfScore - a.rrfScore);

  return scoredResults.slice(0, topK).map((s) => s.result);
}

// ============================================================================
// Hybrid Search with Score Normalization
// ============================================================================

/**
 * Score normalization strategies
 */
export type NormalizationStrategy = 'min-max' | 'z-score' | 'l2' | 'none';

/**
 * Fusion strategies for combining scores
 */
export type FusionStrategy = 'rrf' | 'linear' | 'convex' | 'harmonic';

/**
 * Configuration for hybrid search
 */
export interface HybridSearchConfig {
  /** Boost weight for vector search (0-1) */
  vectorWeight?: number;
  /** Boost weight for text search (0-1) */
  textWeight?: number;
  /** Score normalization strategy */
  normalization?: NormalizationStrategy;
  /** Score fusion strategy */
  fusion?: FusionStrategy;
  /** RRF k parameter (only for RRF fusion) */
  rrfK?: number;
  /** Whether to include individual scores in results */
  includeIndividualScores?: boolean;
}

/**
 * Result with detailed scoring information
 */
export interface HybridSearchResultWithScores extends EnhancedSearchResult {
  /** Original vector search score (before normalization) */
  rawVectorScore?: number;
  /** Original text search score (before normalization) */
  rawTextScore?: number;
  /** Normalized vector score */
  normalizedVectorScore?: number;
  /** Normalized text score */
  normalizedTextScore?: number;
  /** Final fused score */
  fusedScore: number;
  /** Rank in vector results */
  vectorRank?: number;
  /** Rank in text results */
  textRank?: number;
}

/**
 * Normalize scores using min-max normalization
 */
export function normalizeMinMax(scores: number[]): number[] {
  if (scores.length === 0) return [];
  
  const min = Math.min(...scores);
  const max = Math.max(...scores);
  const range = max - min;
  
  if (range === 0) {
    return scores.map(() => 1);
  }
  
  return scores.map((s) => (s - min) / range);
}

/**
 * Normalize scores using z-score normalization
 */
export function normalizeZScore(scores: number[]): number[] {
  if (scores.length === 0) return [];
  
  const mean = scores.reduce((a, b) => a + b, 0) / scores.length;
  const variance =
    scores.reduce((sum, s) => sum + Math.pow(s - mean, 2), 0) / scores.length;
  const stdDev = Math.sqrt(variance);
  
  if (stdDev === 0) {
    return scores.map(() => 0);
  }
  
  return scores.map((s) => (s - mean) / stdDev);
}

/**
 * Normalize scores using L2 normalization
 */
export function normalizeL2(scores: number[]): number[] {
  if (scores.length === 0) return [];
  
  const l2Norm = Math.sqrt(scores.reduce((sum, s) => sum + s * s, 0));
  
  if (l2Norm === 0) {
    return scores.map(() => 0);
  }
  
  return scores.map((s) => s / l2Norm);
}

/**
 * Apply normalization strategy to scores
 */
export function normalizeScores(
  scores: number[],
  strategy: NormalizationStrategy
): number[] {
  switch (strategy) {
    case 'min-max':
      return normalizeMinMax(scores);
    case 'z-score':
      return normalizeZScore(scores);
    case 'l2':
      return normalizeL2(scores);
    case 'none':
    default:
      return [...scores];
  }
}

/**
 * Linear combination of scores
 */
export function fuseLinear(
  vectorScore: number,
  textScore: number,
  vectorWeight: number,
  textWeight: number
): number {
  return vectorScore * vectorWeight + textScore * textWeight;
}

/**
 * Convex combination (weighted average) of scores
 */
export function fuseConvex(
  vectorScore: number,
  textScore: number,
  alpha: number // 0-1, where alpha is vector weight
): number {
  return alpha * vectorScore + (1 - alpha) * textScore;
}

/**
 * Harmonic mean of scores
 */
export function fuseHarmonic(
  vectorScore: number,
  textScore: number,
  vectorWeight: number,
  textWeight: number
): number {
  if (vectorScore === 0 || textScore === 0) {
    return 0;
  }
  
  const totalWeight = vectorWeight + textWeight;
  return (
    totalWeight /
    (vectorWeight / vectorScore + textWeight / textScore)
  );
}

/**
 * Hybrid searcher that combines vector and text search with score normalization
 */
export class HybridSearcher {
  private readonly client: Client;
  private readonly indexName: string;
  private readonly embeddingField: string;
  private readonly contentField: string;
  private readonly metadataField: string;
  private readonly embeddingDims: number;
  private readonly config: Required<HybridSearchConfig>;

  constructor(
    client: Client,
    indexConfig: {
      indexName: string;
      embeddingField?: string;
      contentField?: string;
      metadataField?: string;
      embeddingDims: number;
    },
    searchConfig: HybridSearchConfig = {}
  ) {
    this.client = client;
    this.indexName = indexConfig.indexName;
    this.embeddingField = indexConfig.embeddingField ?? 'embedding';
    this.contentField = indexConfig.contentField ?? 'content';
    this.metadataField = indexConfig.metadataField ?? 'metadata';
    this.embeddingDims = indexConfig.embeddingDims;

    this.config = {
      vectorWeight: searchConfig.vectorWeight ?? 0.5,
      textWeight: searchConfig.textWeight ?? 0.5,
      normalization: searchConfig.normalization ?? 'min-max',
      fusion: searchConfig.fusion ?? 'linear',
      rrfK: searchConfig.rrfK ?? 60,
      includeIndividualScores: searchConfig.includeIndividualScores ?? false,
    };
  }

  /**
   * Get the current configuration
   */
  getConfig(): Required<HybridSearchConfig> {
    return { ...this.config };
  }

  /**
   * Set vector weight
   */
  setVectorWeight(weight: number): this {
    if (weight < 0 || weight > 1) {
      throw new Error('Vector weight must be between 0 and 1');
    }
    this.config.vectorWeight = weight;
    return this;
  }

  /**
   * Set text weight
   */
  setTextWeight(weight: number): this {
    if (weight < 0 || weight > 1) {
      throw new Error('Text weight must be between 0 and 1');
    }
    this.config.textWeight = weight;
    return this;
  }

  /**
   * Set both weights (must sum to 1 for convex combination)
   */
  setWeights(vectorWeight: number, textWeight: number): this {
    this.setVectorWeight(vectorWeight);
    this.setTextWeight(textWeight);
    return this;
  }

  /**
   * Set normalization strategy
   */
  setNormalization(strategy: NormalizationStrategy): this {
    this.config.normalization = strategy;
    return this;
  }

  /**
   * Set fusion strategy
   */
  setFusion(strategy: FusionStrategy): this {
    this.config.fusion = strategy;
    return this;
  }

  /**
   * Perform hybrid search
   */
  async search(
    vector: number[],
    textQuery: string,
    options: {
      k?: number;
      numCandidates?: number;
      filter?: Record<string, unknown>;
      minScore?: number;
      includeEmbedding?: boolean;
    } = {}
  ): Promise<HybridSearchResultWithScores[]> {
    const {
      k = 10,
      numCandidates = k * 4,
      filter,
      minScore,
      includeEmbedding = false,
    } = options;

    // Execute vector search
    const vectorResults = await this.executeVectorSearch(
      vector,
      numCandidates,
      filter
    );

    // Execute text search
    const textResults = await this.executeTextSearch(
      textQuery,
      numCandidates,
      filter
    );

    // Merge and fuse results
    const fusedResults = this.fuseResults(
      vectorResults,
      textResults,
      includeEmbedding
    );

    // Filter by min score if specified
    let filteredResults = fusedResults;
    if (minScore !== undefined) {
      filteredResults = fusedResults.filter((r) => r.fusedScore >= minScore);
    }

    // Return top k
    return filteredResults.slice(0, k);
  }

  /**
   * Execute vector (kNN) search
   */
  private async executeVectorSearch(
    vector: number[],
    k: number,
    filter?: Record<string, unknown>
  ): Promise<Array<{ id: string; score: number; source: Record<string, unknown> }>> {
    const request: Record<string, unknown> = {
      index: this.indexName,
      knn: {
        field: this.embeddingField,
        query_vector: vector,
        k,
        num_candidates: k * 2,
      },
      _source: true,
    };

    if (filter) {
      (request.knn as Record<string, unknown>).filter = filter;
    }

    try {
      const response = await this.client.search(request);

      return response.hits.hits.map((hit) => ({
        id: hit._id ?? '',
        score: hit._score ?? 0,
        source: hit._source as Record<string, unknown>,
      }));
    } catch (error) {
      throw wrapError(error, 'Vector search failed');
    }
  }

  /**
   * Execute text (BM25) search
   */
  private async executeTextSearch(
    query: string,
    size: number,
    filter?: Record<string, unknown>
  ): Promise<Array<{ id: string; score: number; source: Record<string, unknown> }>> {
    const searchQuery: Record<string, unknown> = {
      bool: {
        must: [{ match: { [this.contentField]: query } }],
      },
    };

    if (filter) {
      (searchQuery.bool as Record<string, unknown>).filter = filter;
    }

    try {
      const response = await this.client.search({
        index: this.indexName,
        size,
        query: searchQuery,
        _source: true,
      });

      return response.hits.hits.map((hit) => ({
        id: hit._id ?? '',
        score: hit._score ?? 0,
        source: hit._source as Record<string, unknown>,
      }));
    } catch (error) {
      throw wrapError(error, 'Text search failed');
    }
  }

  /**
   * Fuse vector and text search results
   */
  private fuseResults(
    vectorResults: Array<{ id: string; score: number; source: Record<string, unknown> }>,
    textResults: Array<{ id: string; score: number; source: Record<string, unknown> }>,
    includeEmbedding: boolean
  ): HybridSearchResultWithScores[] {
    // Build lookup maps
    const vectorMap = new Map(
      vectorResults.map((r, idx) => [r.id, { ...r, rank: idx + 1 }])
    );
    const textMap = new Map(
      textResults.map((r, idx) => [r.id, { ...r, rank: idx + 1 }])
    );

    // Get all unique document IDs
    const allIds = new Set([
      ...vectorResults.map((r) => r.id),
      ...textResults.map((r) => r.id),
    ]);

    // Extract scores for normalization
    const vectorScores = vectorResults.map((r) => r.score);
    const textScores = textResults.map((r) => r.score);

    // Normalize scores
    const normalizedVectorScores = normalizeScores(
      vectorScores,
      this.config.normalization
    );
    const normalizedTextScores = normalizeScores(
      textScores,
      this.config.normalization
    );

    // Create normalized score maps
    const vectorNormMap = new Map(
      vectorResults.map((r, idx) => [r.id, normalizedVectorScores[idx]])
    );
    const textNormMap = new Map(
      textResults.map((r, idx) => [r.id, normalizedTextScores[idx]])
    );

    // Fuse scores for each document
    const results: HybridSearchResultWithScores[] = [];

    for (const id of allIds) {
      const vectorItem = vectorMap.get(id);
      const textItem = textMap.get(id);
      const source = vectorItem?.source ?? textItem?.source ?? {};

      const rawVectorScore = vectorItem?.score ?? 0;
      const rawTextScore = textItem?.score ?? 0;
      const normalizedVectorScore = vectorNormMap.get(id) ?? 0;
      const normalizedTextScore = textNormMap.get(id) ?? 0;
      const vectorRank = vectorItem?.rank;
      const textRank = textItem?.rank;

      // Calculate fused score based on strategy
      let fusedScore: number;

      switch (this.config.fusion) {
        case 'rrf':
          fusedScore = calculateRrfScore(
            [vectorRank ?? 1000, textRank ?? 1000],
            this.config.rrfK
          );
          break;

        case 'convex':
          fusedScore = fuseConvex(
            normalizedVectorScore,
            normalizedTextScore,
            this.config.vectorWeight
          );
          break;

        case 'harmonic':
          fusedScore = fuseHarmonic(
            normalizedVectorScore,
            normalizedTextScore,
            this.config.vectorWeight,
            this.config.textWeight
          );
          break;

        case 'linear':
        default:
          fusedScore = fuseLinear(
            normalizedVectorScore,
            normalizedTextScore,
            this.config.vectorWeight,
            this.config.textWeight
          );
          break;
      }

      const result: HybridSearchResultWithScores = {
        id,
        score: fusedScore,
        fusedScore,
        content: source[this.contentField] as string,
        metadata: source[this.metadataField] as Record<string, unknown>,
      };

      if (includeEmbedding && source[this.embeddingField]) {
        result.embedding = source[this.embeddingField] as number[];
      }

      if (this.config.includeIndividualScores) {
        result.rawVectorScore = rawVectorScore;
        result.rawTextScore = rawTextScore;
        result.normalizedVectorScore = normalizedVectorScore;
        result.normalizedTextScore = normalizedTextScore;
        result.vectorScore = normalizedVectorScore;
        result.textScore = normalizedTextScore;
        result.vectorRank = vectorRank;
        result.textRank = textRank;
      }

      results.push(result);
    }

    // Sort by fused score
    results.sort((a, b) => b.fusedScore - a.fusedScore);

    return results;
  }
}

// ============================================================================
// Factory Functions for HybridSearcher
// ============================================================================

/**
 * Create a hybrid searcher with default configuration
 */
export function createHybridSearcher(
  client: Client,
  indexConfig: {
    indexName: string;
    embeddingField?: string;
    contentField?: string;
    metadataField?: string;
    embeddingDims: number;
  },
  searchConfig?: HybridSearchConfig
): HybridSearcher {
  return new HybridSearcher(client, indexConfig, searchConfig);
}

/**
 * Create a hybrid searcher optimized for semantic search (high vector weight)
 */
export function createSemanticSearcher(
  client: Client,
  indexConfig: {
    indexName: string;
    embeddingField?: string;
    contentField?: string;
    metadataField?: string;
    embeddingDims: number;
  }
): HybridSearcher {
  return new HybridSearcher(client, indexConfig, {
    vectorWeight: 0.8,
    textWeight: 0.2,
    normalization: 'min-max',
    fusion: 'linear',
  });
}

/**
 * Create a hybrid searcher optimized for keyword search (high text weight)
 */
export function createKeywordSearcher(
  client: Client,
  indexConfig: {
    indexName: string;
    embeddingField?: string;
    contentField?: string;
    metadataField?: string;
    embeddingDims: number;
  }
): HybridSearcher {
  return new HybridSearcher(client, indexConfig, {
    vectorWeight: 0.2,
    textWeight: 0.8,
    normalization: 'min-max',
    fusion: 'linear',
  });
}

/**
 * Create a hybrid searcher using RRF fusion
 */
export function createRrfSearcher(
  client: Client,
  indexConfig: {
    indexName: string;
    embeddingField?: string;
    contentField?: string;
    metadataField?: string;
    embeddingDims: number;
  },
  rrfK: number = 60
): HybridSearcher {
  return new HybridSearcher(client, indexConfig, {
    fusion: 'rrf',
    rrfK,
    // Weights don't affect RRF but are included for API consistency
    vectorWeight: 0.5,
    textWeight: 0.5,
  });
}

/**
 * Create a hybrid searcher with equal weighting (balanced)
 */
export function createBalancedSearcher(
  client: Client,
  indexConfig: {
    indexName: string;
    embeddingField?: string;
    contentField?: string;
    metadataField?: string;
    embeddingDims: number;
  }
): HybridSearcher {
  return new HybridSearcher(client, indexConfig, {
    vectorWeight: 0.5,
    textWeight: 0.5,
    normalization: 'min-max',
    fusion: 'convex',
  });
}

// ============================================================================
// Utility Functions
// ============================================================================

/**
 * Calculate optimal weights using click-through data or relevance feedback
 */
export function tuneWeights(
  results: Array<{
    vectorScore: number;
    textScore: number;
    relevanceLabel: number; // 0 = not relevant, 1 = relevant
  }>
): { vectorWeight: number; textWeight: number } {
  // Simple linear regression to find optimal weights
  // This is a simplified implementation; production would use gradient descent
  
  let bestVectorWeight = 0.5;
  let bestScore = -Infinity;

  // Grid search over weight combinations
  for (let vw = 0; vw <= 1; vw += 0.1) {
    const tw = 1 - vw;
    
    let score = 0;
    for (const r of results) {
      const fusedScore = r.vectorScore * vw + r.textScore * tw;
      // Higher fused score for relevant items = better
      score += fusedScore * r.relevanceLabel;
      // Lower fused score for non-relevant items = better
      score -= fusedScore * (1 - r.relevanceLabel);
    }

    if (score > bestScore) {
      bestScore = score;
      bestVectorWeight = vw;
    }
  }

  return {
    vectorWeight: bestVectorWeight,
    textWeight: 1 - bestVectorWeight,
  };
}

/**
 * Calculate search quality metrics
 */
export function calculateSearchMetrics(
  results: Array<{ score: number; isRelevant: boolean }>,
  k?: number
): {
  precision: number;
  recall: number;
  f1: number;
  ndcg: number;
  mrr: number;
} {
  const topK = k ?? results.length;
  const topResults = results.slice(0, topK);
  
  const relevantInTopK = topResults.filter((r) => r.isRelevant).length;
  const totalRelevant = results.filter((r) => r.isRelevant).length;

  // Precision@k
  const precision = relevantInTopK / topK;

  // Recall@k
  const recall = totalRelevant > 0 ? relevantInTopK / totalRelevant : 0;

  // F1 score
  const f1 =
    precision + recall > 0
      ? (2 * precision * recall) / (precision + recall)
      : 0;

  // NDCG@k (Normalized Discounted Cumulative Gain)
  let dcg = 0;
  let idcg = 0;
  const sortedRelevance = results
    .map((r) => (r.isRelevant ? 1 : 0))
    .sort((a, b) => b - a);

  for (let i = 0; i < topK; i++) {
    const rel = topResults[i]?.isRelevant ? 1 : 0;
    dcg += rel / Math.log2(i + 2);
    idcg += (sortedRelevance[i] ?? 0) / Math.log2(i + 2);
  }
  const ndcg = idcg > 0 ? dcg / idcg : 0;

  // MRR (Mean Reciprocal Rank)
  let mrr = 0;
  for (let i = 0; i < topResults.length; i++) {
    if (topResults[i].isRelevant) {
      mrr = 1 / (i + 1);
      break;
    }
  }

  return { precision, recall, f1, ndcg, mrr };
}
