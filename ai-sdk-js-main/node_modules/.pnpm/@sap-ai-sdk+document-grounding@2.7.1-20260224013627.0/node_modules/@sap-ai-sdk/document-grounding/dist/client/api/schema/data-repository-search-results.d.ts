import type { DataRepositoryPerFilterSearchResult } from './data-repository-per-filter-search-result.js';
import type { PerFilterSearchResultWithError } from './per-filter-search-result-with-error.js';
/**
 * Representation of the 'DataRepositorySearchResults' schema.
 */
export type DataRepositorySearchResults = {
    /**
     * List of returned results.
     */
    results: (DataRepositoryPerFilterSearchResult | PerFilterSearchResultWithError)[];
} & Record<string, any>;
//# sourceMappingURL=data-repository-search-results.d.ts.map