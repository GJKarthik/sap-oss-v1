import type { PerFilterSearchResult } from './per-filter-search-result.js';
/**
 * Representation of the 'SearchResults' schema.
 */
export type SearchResults = {
    /**
     * List of returned results.
     */
    results: PerFilterSearchResult[];
} & Record<string, any>;
//# sourceMappingURL=search-results.d.ts.map