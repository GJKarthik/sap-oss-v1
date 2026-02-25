/**
 * @sap-ai-sdk/elasticsearch - Pagination
 *
 * Pagination utilities for Elasticsearch search results.
 */

import { Client } from '@elastic/elasticsearch';
import type { SearchResult } from './types.js';
import { wrapError } from './errors.js';

// ============================================================================
// Types
// ============================================================================

/**
 * Pagination strategy
 */
export type PaginationStrategy = 'offset' | 'search_after' | 'scroll' | 'pit';

/**
 * Sort direction
 */
export type SortDirection = 'asc' | 'desc';

/**
 * Sort configuration
 */
export interface SortConfig {
  /** Field to sort by */
  field: string;
  /** Sort direction */
  order?: SortDirection;
  /** Handle missing values */
  missing?: '_first' | '_last' | unknown;
  /** Unmapped type */
  unmappedType?: string;
}

/**
 * Pagination options
 */
export interface PaginationOptions {
  /** Page size (default: 10) */
  pageSize?: number;
  /** Current page (1-indexed, for offset pagination) */
  page?: number;
  /** Maximum results to return (hard limit) */
  maxResults?: number;
  /** Sort configuration */
  sort?: SortConfig[];
  /** Search after values (for cursor pagination) */
  searchAfter?: unknown[];
  /** Scroll context ID (for scroll pagination) */
  scrollId?: string;
  /** Point-in-time ID (for PIT pagination) */
  pitId?: string;
  /** Scroll keep-alive (e.g., '1m', '5m') */
  scrollKeepAlive?: string;
  /** PIT keep-alive */
  pitKeepAlive?: string;
}

/**
 * Paginated result set
 */
export interface PaginatedResults<T = SearchResult> {
  /** Results for current page */
  results: T[];
  /** Total number of results */
  total: number;
  /** Current page (1-indexed) */
  page: number;
  /** Page size */
  pageSize: number;
  /** Total number of pages */
  totalPages: number;
  /** Whether there's a next page */
  hasNextPage: boolean;
  /** Whether there's a previous page */
  hasPreviousPage: boolean;
  /** Search after values for next page */
  nextSearchAfter?: unknown[];
  /** Scroll ID for scroll pagination */
  scrollId?: string;
  /** PIT ID for PIT pagination */
  pitId?: string;
  /** Time taken in milliseconds */
  took: number;
}

/**
 * Cursor for pagination
 */
export interface PageCursor {
  /** Strategy used */
  strategy: PaginationStrategy;
  /** Search after values */
  searchAfter?: unknown[];
  /** Scroll ID */
  scrollId?: string;
  /** PIT ID */
  pitId?: string;
  /** Current offset */
  offset?: number;
}

/**
 * Page info for GraphQL-style pagination
 */
export interface PageInfo {
  /** Has next page */
  hasNextPage: boolean;
  /** Has previous page */
  hasPreviousPage: boolean;
  /** Start cursor */
  startCursor?: string;
  /** End cursor */
  endCursor?: string;
}

/**
 * Connection-style results (GraphQL Relay spec)
 */
export interface Connection<T = SearchResult> {
  /** Edges with cursor */
  edges: Array<{
    node: T;
    cursor: string;
  }>;
  /** Page info */
  pageInfo: PageInfo;
  /** Total count */
  totalCount: number;
}

// ============================================================================
// Paginator Class
// ============================================================================

/**
 * Paginator for managing search result pagination
 */
export class Paginator<T = SearchResult> {
  private readonly client: Client;
  private readonly indexName: string;
  private readonly pageSize: number;
  private readonly maxResults: number;
  private readonly strategy: PaginationStrategy;
  private readonly scrollKeepAlive: string;
  private readonly pitKeepAlive: string;
  private readonly defaultSort: SortConfig[];
  private readonly sourceExcludes: string[];

  // State
  private currentPage: number = 0;
  private searchAfter?: unknown[];
  private scrollId?: string;
  private pitId?: string;
  private totalResults?: number;
  private baseQuery?: Record<string, unknown>;
  private isExhausted: boolean = false;

  constructor(
    client: Client,
    indexName: string,
    options: {
      pageSize?: number;
      maxResults?: number;
      strategy?: PaginationStrategy;
      scrollKeepAlive?: string;
      pitKeepAlive?: string;
      defaultSort?: SortConfig[];
      sourceExcludes?: string[];
    } = {}
  ) {
    this.client = client;
    this.indexName = indexName;
    this.pageSize = options.pageSize ?? 10;
    this.maxResults = options.maxResults ?? 10000;
    this.strategy = options.strategy ?? 'search_after';
    this.scrollKeepAlive = options.scrollKeepAlive ?? '5m';
    this.pitKeepAlive = options.pitKeepAlive ?? '5m';
    this.defaultSort = options.defaultSort ?? [{ field: '_score', order: 'desc' }];
    this.sourceExcludes = options.sourceExcludes ?? [];
  }

  /**
   * Set the base query for pagination
   */
  setQuery(query: Record<string, unknown>): this {
    this.baseQuery = query;
    this.reset();
    return this;
  }

  /**
   * Reset pagination state
   */
  reset(): void {
    this.currentPage = 0;
    this.searchAfter = undefined;
    this.scrollId = undefined;
    this.totalResults = undefined;
    this.isExhausted = false;
  }

  /**
   * Get current page number (1-indexed)
   */
  getCurrentPage(): number {
    return this.currentPage;
  }

  /**
   * Get total results count
   */
  getTotalResults(): number | undefined {
    return this.totalResults;
  }

  /**
   * Check if more results are available
   */
  hasMore(): boolean {
    return !this.isExhausted;
  }

  /**
   * Fetch next page
   */
  async nextPage(): Promise<PaginatedResults<T>> {
    if (this.isExhausted) {
      return this.createEmptyPage();
    }

    switch (this.strategy) {
      case 'offset':
        return this.fetchOffsetPage(this.currentPage + 1);
      case 'search_after':
        return this.fetchSearchAfterPage();
      case 'scroll':
        return this.fetchScrollPage();
      case 'pit':
        return this.fetchPitPage();
      default:
        return this.fetchSearchAfterPage();
    }
  }

  /**
   * Fetch specific page (only for offset pagination)
   */
  async goToPage(page: number): Promise<PaginatedResults<T>> {
    if (this.strategy !== 'offset') {
      throw new Error('goToPage is only supported with offset pagination');
    }
    return this.fetchOffsetPage(page);
  }

  /**
   * Fetch first page
   */
  async firstPage(): Promise<PaginatedResults<T>> {
    this.reset();
    return this.nextPage();
  }

  /**
   * Close pagination resources (scroll/PIT)
   */
  async close(): Promise<void> {
    if (this.scrollId) {
      try {
        await this.client.clearScroll({ scroll_id: this.scrollId });
      } catch {
        // Ignore errors on cleanup
      }
      this.scrollId = undefined;
    }

    if (this.pitId) {
      try {
        await this.client.closePointInTime({ id: this.pitId });
      } catch {
        // Ignore errors on cleanup
      }
      this.pitId = undefined;
    }
  }

  // ============================================================================
  // Strategy Implementations
  // ============================================================================

  /**
   * Offset-based pagination
   */
  private async fetchOffsetPage(page: number): Promise<PaginatedResults<T>> {
    const from = (page - 1) * this.pageSize;
    
    // Elasticsearch has a 10k limit by default
    if (from >= this.maxResults) {
      this.isExhausted = true;
      return this.createEmptyPage();
    }

    const request: Record<string, unknown> = {
      index: this.indexName,
      from,
      size: Math.min(this.pageSize, this.maxResults - from),
      query: this.baseQuery ?? { match_all: {} },
      sort: this.buildSort(),
      track_total_hits: true,
    };

    if (this.sourceExcludes.length > 0) {
      request._source = { excludes: this.sourceExcludes };
    }

    try {
      const response = await this.client.search(request);
      const total = typeof response.hits.total === 'number'
        ? response.hits.total
        : response.hits.total?.value ?? 0;

      this.totalResults = total;
      this.currentPage = page;

      const results = this.transformHits(response.hits.hits);
      const totalPages = Math.ceil(Math.min(total, this.maxResults) / this.pageSize);

      this.isExhausted = page >= totalPages || from + results.length >= this.maxResults;

      return {
        results,
        total,
        page,
        pageSize: this.pageSize,
        totalPages,
        hasNextPage: page < totalPages,
        hasPreviousPage: page > 1,
        took: response.took,
      };
    } catch (error) {
      throw wrapError(error, 'Offset pagination failed');
    }
  }

  /**
   * Search after pagination (cursor-based)
   */
  private async fetchSearchAfterPage(): Promise<PaginatedResults<T>> {
    const request: Record<string, unknown> = {
      index: this.indexName,
      size: this.pageSize,
      query: this.baseQuery ?? { match_all: {} },
      sort: this.buildSort(),
      track_total_hits: this.currentPage === 0, // Only track on first page
    };

    if (this.searchAfter) {
      request.search_after = this.searchAfter;
    }

    if (this.sourceExcludes.length > 0) {
      request._source = { excludes: this.sourceExcludes };
    }

    try {
      const response = await this.client.search(request);
      
      if (this.currentPage === 0) {
        const total = typeof response.hits.total === 'number'
          ? response.hits.total
          : response.hits.total?.value ?? 0;
        this.totalResults = total;
      }

      this.currentPage++;

      const hits = response.hits.hits;
      const results = this.transformHits(hits);

      // Update search_after with last result's sort values
      if (hits.length > 0 && hits[hits.length - 1].sort) {
        this.searchAfter = hits[hits.length - 1].sort;
      }

      this.isExhausted = results.length < this.pageSize;
      const totalPages = this.totalResults 
        ? Math.ceil(this.totalResults / this.pageSize) 
        : undefined;

      return {
        results,
        total: this.totalResults ?? 0,
        page: this.currentPage,
        pageSize: this.pageSize,
        totalPages: totalPages ?? 0,
        hasNextPage: !this.isExhausted,
        hasPreviousPage: this.currentPage > 1,
        nextSearchAfter: this.searchAfter,
        took: response.took,
      };
    } catch (error) {
      throw wrapError(error, 'Search after pagination failed');
    }
  }

  /**
   * Scroll pagination
   */
  private async fetchScrollPage(): Promise<PaginatedResults<T>> {
    try {
      let response;

      if (!this.scrollId) {
        // Initial scroll request
        response = await this.client.search({
          index: this.indexName,
          size: this.pageSize,
          query: this.baseQuery ?? { match_all: {} },
          sort: this.buildSort(),
          scroll: this.scrollKeepAlive,
          _source: this.sourceExcludes.length > 0 
            ? { excludes: this.sourceExcludes } 
            : undefined,
        } as Record<string, unknown>);

        const total = typeof response.hits.total === 'number'
          ? response.hits.total
          : response.hits.total?.value ?? 0;
        this.totalResults = total;
      } else {
        // Continue scroll
        response = await this.client.scroll({
          scroll_id: this.scrollId,
          scroll: this.scrollKeepAlive,
        });
      }

      this.scrollId = response._scroll_id;
      this.currentPage++;

      const results = this.transformHits(response.hits.hits);
      this.isExhausted = results.length === 0;

      const totalPages = this.totalResults 
        ? Math.ceil(this.totalResults / this.pageSize) 
        : undefined;

      return {
        results,
        total: this.totalResults ?? 0,
        page: this.currentPage,
        pageSize: this.pageSize,
        totalPages: totalPages ?? 0,
        hasNextPage: !this.isExhausted,
        hasPreviousPage: this.currentPage > 1,
        scrollId: this.scrollId,
        took: response.took,
      };
    } catch (error) {
      throw wrapError(error, 'Scroll pagination failed');
    }
  }

  /**
   * Point-in-time pagination
   */
  private async fetchPitPage(): Promise<PaginatedResults<T>> {
    try {
      // Create PIT on first request
      if (!this.pitId) {
        const pit = await this.client.openPointInTime({
          index: this.indexName,
          keep_alive: this.pitKeepAlive,
        });
        this.pitId = pit.id;
      }

      const request: Record<string, unknown> = {
        size: this.pageSize,
        query: this.baseQuery ?? { match_all: {} },
        sort: this.buildSort(),
        pit: {
          id: this.pitId,
          keep_alive: this.pitKeepAlive,
        },
        track_total_hits: this.currentPage === 0,
      };

      if (this.searchAfter) {
        request.search_after = this.searchAfter;
      }

      if (this.sourceExcludes.length > 0) {
        request._source = { excludes: this.sourceExcludes };
      }

      const response = await this.client.search(request);

      if (this.currentPage === 0) {
        const total = typeof response.hits.total === 'number'
          ? response.hits.total
          : response.hits.total?.value ?? 0;
        this.totalResults = total;
      }

      // Update PIT ID (it may change between requests)
      this.pitId = (response as unknown as { pit_id?: string }).pit_id ?? this.pitId;
      this.currentPage++;

      const hits = response.hits.hits;
      const results = this.transformHits(hits);

      if (hits.length > 0 && hits[hits.length - 1].sort) {
        this.searchAfter = hits[hits.length - 1].sort;
      }

      this.isExhausted = results.length < this.pageSize;
      const totalPages = this.totalResults 
        ? Math.ceil(this.totalResults / this.pageSize) 
        : undefined;

      return {
        results,
        total: this.totalResults ?? 0,
        page: this.currentPage,
        pageSize: this.pageSize,
        totalPages: totalPages ?? 0,
        hasNextPage: !this.isExhausted,
        hasPreviousPage: this.currentPage > 1,
        nextSearchAfter: this.searchAfter,
        pitId: this.pitId,
        took: response.took,
      };
    } catch (error) {
      throw wrapError(error, 'PIT pagination failed');
    }
  }

  // ============================================================================
  // Helpers
  // ============================================================================

  /**
   * Build sort array for Elasticsearch
   */
  private buildSort(): Array<Record<string, unknown>> {
    return this.defaultSort.map((s) => ({
      [s.field]: {
        order: s.order ?? 'desc',
        ...(s.missing && { missing: s.missing }),
        ...(s.unmappedType && { unmapped_type: s.unmappedType }),
      },
    }));
  }

  /**
   * Transform search hits to results
   */
  private transformHits(hits: unknown[]): T[] {
    return hits.map((hit) => {
      const h = hit as Record<string, unknown>;
      const source = h._source as Record<string, unknown>;
      return {
        id: h._id ?? '',
        score: h._score ?? 0,
        content: source?.content as string,
        metadata: source?.metadata as Record<string, unknown>,
        ...(source?.embedding && { embedding: source.embedding as number[] }),
      } as T;
    });
  }

  /**
   * Create empty page result
   */
  private createEmptyPage(): PaginatedResults<T> {
    return {
      results: [],
      total: this.totalResults ?? 0,
      page: this.currentPage,
      pageSize: this.pageSize,
      totalPages: this.totalResults 
        ? Math.ceil(this.totalResults / this.pageSize) 
        : 0,
      hasNextPage: false,
      hasPreviousPage: this.currentPage > 1,
      took: 0,
    };
  }
}

// ============================================================================
// Factory Functions
// ============================================================================

/**
 * Create a paginator with search_after strategy
 */
export function createPaginator<T = SearchResult>(
  client: Client,
  indexName: string,
  options?: {
    pageSize?: number;
    maxResults?: number;
    defaultSort?: SortConfig[];
    sourceExcludes?: string[];
  }
): Paginator<T> {
  return new Paginator<T>(client, indexName, {
    ...options,
    strategy: 'search_after',
  });
}

/**
 * Create a paginator with scroll strategy (for large exports)
 */
export function createScrollPaginator<T = SearchResult>(
  client: Client,
  indexName: string,
  options?: {
    pageSize?: number;
    scrollKeepAlive?: string;
    sourceExcludes?: string[];
  }
): Paginator<T> {
  return new Paginator<T>(client, indexName, {
    ...options,
    strategy: 'scroll',
    maxResults: Infinity,
  });
}

/**
 * Create a paginator with PIT strategy (consistent snapshots)
 */
export function createPitPaginator<T = SearchResult>(
  client: Client,
  indexName: string,
  options?: {
    pageSize?: number;
    pitKeepAlive?: string;
    defaultSort?: SortConfig[];
    sourceExcludes?: string[];
  }
): Paginator<T> {
  return new Paginator<T>(client, indexName, {
    ...options,
    strategy: 'pit',
  });
}

// ============================================================================
// Utility Functions
// ============================================================================

/**
 * Collect all results from paginator
 */
export async function collectAllResults<T = SearchResult>(
  paginator: Paginator<T>,
  maxResults: number = Infinity
): Promise<T[]> {
  const results: T[] = [];

  try {
    while (paginator.hasMore() && results.length < maxResults) {
      const page = await paginator.nextPage();
      results.push(...page.results);

      if (!page.hasNextPage) {
        break;
      }
    }
  } finally {
    await paginator.close();
  }

  return results.slice(0, maxResults);
}

/**
 * Iterate through all pages
 */
export async function* iteratePages<T = SearchResult>(
  paginator: Paginator<T>
): AsyncGenerator<PaginatedResults<T>, void, unknown> {
  try {
    while (paginator.hasMore()) {
      const page = await paginator.nextPage();
      yield page;

      if (!page.hasNextPage) {
        break;
      }
    }
  } finally {
    await paginator.close();
  }
}

/**
 * Process all results with a callback
 */
export async function processAllResults<T = SearchResult>(
  paginator: Paginator<T>,
  processor: (results: T[], page: number) => void | Promise<void>,
  options: { parallel?: boolean } = {}
): Promise<{ totalProcessed: number; totalPages: number }> {
  let totalProcessed = 0;
  let totalPages = 0;

  try {
    while (paginator.hasMore()) {
      const page = await paginator.nextPage();
      totalPages++;

      if (options.parallel) {
        // Don't await - allow parallel processing
        void processor(page.results, page.page);
      } else {
        await processor(page.results, page.page);
      }

      totalProcessed += page.results.length;

      if (!page.hasNextPage) {
        break;
      }
    }
  } finally {
    await paginator.close();
  }

  return { totalProcessed, totalPages };
}

/**
 * Encode cursor for client
 */
export function encodeCursor(cursor: PageCursor): string {
  return Buffer.from(JSON.stringify(cursor)).toString('base64url');
}

/**
 * Decode cursor from client
 */
export function decodeCursor(encoded: string): PageCursor {
  try {
    return JSON.parse(Buffer.from(encoded, 'base64url').toString('utf-8'));
  } catch {
    throw new Error('Invalid cursor');
  }
}

/**
 * Create cursor from paginated results
 */
export function createCursor(
  results: PaginatedResults,
  strategy: PaginationStrategy = 'search_after'
): string | undefined {
  if (!results.hasNextPage) {
    return undefined;
  }

  const cursor: PageCursor = { strategy };

  switch (strategy) {
    case 'search_after':
      if (results.nextSearchAfter) {
        cursor.searchAfter = results.nextSearchAfter;
      }
      break;
    case 'scroll':
      if (results.scrollId) {
        cursor.scrollId = results.scrollId;
      }
      break;
    case 'pit':
      cursor.pitId = results.pitId;
      cursor.searchAfter = results.nextSearchAfter;
      break;
    case 'offset':
      cursor.offset = results.page * results.pageSize;
      break;
  }

  return encodeCursor(cursor);
}

/**
 * Convert to GraphQL Connection format
 */
export function toConnection<T = SearchResult>(
  results: PaginatedResults<T>,
  getId: (item: T) => string = (item) => (item as unknown as { id: string }).id
): Connection<T> {
  const edges = results.results.map((node, index) => ({
    node,
    cursor: encodeCursor({
      strategy: 'offset',
      offset: (results.page - 1) * results.pageSize + index,
    }),
  }));

  return {
    edges,
    pageInfo: {
      hasNextPage: results.hasNextPage,
      hasPreviousPage: results.hasPreviousPage,
      startCursor: edges.length > 0 ? edges[0].cursor : undefined,
      endCursor: edges.length > 0 ? edges[edges.length - 1].cursor : undefined,
    },
    totalCount: results.total,
  };
}

/**
 * Calculate pagination info
 */
export function calculatePaginationInfo(
  total: number,
  page: number,
  pageSize: number
): {
  totalPages: number;
  hasNextPage: boolean;
  hasPreviousPage: boolean;
  startIndex: number;
  endIndex: number;
} {
  const totalPages = Math.ceil(total / pageSize);
  const startIndex = (page - 1) * pageSize;
  const endIndex = Math.min(startIndex + pageSize - 1, total - 1);

  return {
    totalPages,
    hasNextPage: page < totalPages,
    hasPreviousPage: page > 1,
    startIndex,
    endIndex: Math.max(endIndex, 0),
  };
}

/**
 * Create page range for UI pagination
 */
export function createPageRange(
  currentPage: number,
  totalPages: number,
  windowSize: number = 5
): Array<number | 'ellipsis'> {
  if (totalPages <= windowSize + 2) {
    return Array.from({ length: totalPages }, (_, i) => i + 1);
  }

  const range: Array<number | 'ellipsis'> = [];
  const halfWindow = Math.floor(windowSize / 2);

  // Always show first page
  range.push(1);

  // Calculate window start and end
  let windowStart = Math.max(2, currentPage - halfWindow);
  let windowEnd = Math.min(totalPages - 1, currentPage + halfWindow);

  // Adjust window if at boundaries
  if (windowStart === 2) {
    windowEnd = Math.min(totalPages - 1, windowSize);
  }
  if (windowEnd === totalPages - 1) {
    windowStart = Math.max(2, totalPages - windowSize);
  }

  // Add ellipsis before window if needed
  if (windowStart > 2) {
    range.push('ellipsis');
  }

  // Add window pages
  for (let i = windowStart; i <= windowEnd; i++) {
    range.push(i);
  }

  // Add ellipsis after window if needed
  if (windowEnd < totalPages - 1) {
    range.push('ellipsis');
  }

  // Always show last page
  if (totalPages > 1) {
    range.push(totalPages);
  }

  return range;
}