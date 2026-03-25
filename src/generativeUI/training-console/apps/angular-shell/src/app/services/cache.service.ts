import { Injectable, signal, computed } from '@angular/core';
import { Observable, of, tap, shareReplay, timer, switchMap, catchError } from 'rxjs';

/**
 * Cache entry with metadata for stale-while-revalidate strategy
 */
interface CacheEntry<T> {
  data: T;
  timestamp: number;
  observable$: Observable<T>;
}

/**
 * Cache configuration for each endpoint
 */
interface CacheConfig {
  /** Time in ms before data is considered stale (will revalidate in background) */
  staleTime: number;
  /** Time in ms before data is considered expired (will force fetch) */
  maxAge: number;
}

/**
 * Default cache configurations for common endpoints
 */
const DEFAULT_CACHE_CONFIGS: Record<string, CacheConfig> = {
  '/health': { staleTime: 30_000, maxAge: 60_000 },
  '/gpu/status': { staleTime: 10_000, maxAge: 30_000 },
  '/graph/stats': { staleTime: 60_000, maxAge: 120_000 },
  '/models/catalog': { staleTime: 300_000, maxAge: 600_000 },
  '/jobs': { staleTime: 5_000, maxAge: 15_000 },
};

/**
 * CacheService implements the stale-while-revalidate pattern for API responses.
 * 
 * - **Fresh**: Data is within staleTime, served immediately from cache
 * - **Stale**: Data is between staleTime and maxAge, served from cache while revalidating
 * - **Expired**: Data is beyond maxAge, forces a fresh fetch
 * 
 * @example
 * ```typescript
 * // In a service or component:
 * this.cache.get('/health', () => this.http.get<HealthStatus>('/api/health'))
 *   .subscribe(data => console.log(data));
 * ```
 */
@Injectable({ providedIn: 'root' })
export class CacheService {
  private cache = new Map<string, CacheEntry<unknown>>();
  private pendingRequests = new Map<string, Observable<unknown>>();
  
  // Observable stats for debugging
  private _hitCount = signal(0);
  private _missCount = signal(0);
  private _staleCount = signal(0);
  
  readonly stats = computed(() => ({
    hits: this._hitCount(),
    misses: this._missCount(),
    stale: this._staleCount(),
    hitRate: this._hitCount() / Math.max(1, this._hitCount() + this._missCount()),
    entries: this.cache.size,
  }));

  /**
   * Get data from cache or fetch from source.
   * Implements stale-while-revalidate strategy.
   * 
   * @param key - Unique cache key (typically the endpoint URL)
   * @param fetchFn - Function that returns an Observable to fetch fresh data
   * @param config - Optional cache configuration override
   */
  get<T>(
    key: string,
    fetchFn: () => Observable<T>,
    config?: Partial<CacheConfig>
  ): Observable<T> {
    const cacheConfig = this.getConfig(key, config);
    const entry = this.cache.get(key) as CacheEntry<T> | undefined;
    const now = Date.now();
    
    // Check if we have valid cached data
    if (entry) {
      const age = now - entry.timestamp;
      
      // Fresh data - serve from cache
      if (age < cacheConfig.staleTime) {
        this._hitCount.update((c) => c + 1);
        return of(entry.data);
      }
      
      // Stale data - serve from cache but revalidate in background
      if (age < cacheConfig.maxAge) {
        this._staleCount.update((c) => c + 1);
        this.revalidateInBackground(key, fetchFn);
        return of(entry.data);
      }
    }
    
    // Expired or no cache - fetch fresh data
    this._missCount.update((c) => c + 1);
    return this.fetchAndCache(key, fetchFn);
  }

  /**
   * Invalidate a specific cache entry
   */
  invalidate(key: string): void {
    this.cache.delete(key);
    this.pendingRequests.delete(key);
  }

  /**
   * Invalidate all cache entries matching a pattern
   */
  invalidatePattern(pattern: RegExp): void {
    for (const key of this.cache.keys()) {
      if (pattern.test(key)) {
        this.cache.delete(key);
      }
    }
  }

  /**
   * Clear all cached data
   */
  clear(): void {
    this.cache.clear();
    this.pendingRequests.clear();
    this._hitCount.set(0);
    this._missCount.set(0);
    this._staleCount.set(0);
  }

  /**
   * Prefetch data into cache
   */
  prefetch<T>(key: string, fetchFn: () => Observable<T>, config?: Partial<CacheConfig>): void {
    const entry = this.cache.get(key);
    const cacheConfig = this.getConfig(key, config);
    
    // Only prefetch if no valid cache exists
    if (!entry || Date.now() - entry.timestamp > cacheConfig.staleTime) {
      this.fetchAndCache(key, fetchFn).subscribe();
    }
  }

  /**
   * Check if a key has valid (non-stale) cached data
   */
  has(key: string): boolean {
    const entry = this.cache.get(key);
    if (!entry) return false;
    
    const config = this.getConfig(key);
    return Date.now() - entry.timestamp < config.staleTime;
  }

  /**
   * Get cache age in milliseconds
   */
  getAge(key: string): number | null {
    const entry = this.cache.get(key);
    return entry ? Date.now() - entry.timestamp : null;
  }

  // ===========================================================================
  // Private Methods
  // ===========================================================================

  private getConfig(key: string, override?: Partial<CacheConfig>): CacheConfig {
    const defaultConfig = DEFAULT_CACHE_CONFIGS[key] ?? { staleTime: 60_000, maxAge: 300_000 };
    return { ...defaultConfig, ...override };
  }

  private fetchAndCache<T>(key: string, fetchFn: () => Observable<T>): Observable<T> {
    // Check if there's already a pending request for this key
    const pending = this.pendingRequests.get(key) as Observable<T> | undefined;
    if (pending) {
      return pending;
    }

    // Create new request with shareReplay to dedupe
    const request$ = fetchFn().pipe(
      tap((data) => {
        this.cache.set(key, {
          data,
          timestamp: Date.now(),
          observable$: of(data),
        });
        this.pendingRequests.delete(key);
      }),
      catchError((error) => {
        this.pendingRequests.delete(key);
        throw error;
      }),
      shareReplay(1)
    );

    this.pendingRequests.set(key, request$);
    return request$;
  }

  private revalidateInBackground<T>(key: string, fetchFn: () => Observable<T>): void {
    // Don't revalidate if already pending
    if (this.pendingRequests.has(key)) {
      return;
    }

    // Use setTimeout to push to next tick (non-blocking)
    setTimeout(() => {
      this.fetchAndCache(key, fetchFn).subscribe({
        error: (err) => console.warn(`Background revalidation failed for ${key}:`, err),
      });
    }, 0);
  }
}

/**
 * Decorator to auto-cache method results.
 * Requires the class to have a CacheService injected as 'cache'.
 * 
 * @example
 * ```typescript
 * class MyService {
 *   cache = inject(CacheService);
 *   
 *   @Cached('/api/items', { staleTime: 30000 })
 *   getItems(): Observable<Item[]> {
 *     return this.http.get<Item[]>('/api/items');
 *   }
 * }
 * ```
 */
export function Cached(key: string, config?: Partial<CacheConfig>) {
  return function (
    target: unknown,
    propertyKey: string,
    descriptor: PropertyDescriptor
  ) {
    const originalMethod = descriptor.value;

    descriptor.value = function (this: { cache: CacheService }, ...args: unknown[]) {
      const dynamicKey = args.length > 0 ? `${key}:${JSON.stringify(args)}` : key;
      return this.cache.get(dynamicKey, () => originalMethod.apply(this, args), config);
    };

    return descriptor;
  };
}