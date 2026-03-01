import type { DataRepositorySearchResult } from './data-repository-search-result.js';
/**
 * Representation of the 'DataRepositoryPerFilterSearchResult' schema.
 */
export type DataRepositoryPerFilterSearchResult = {
    filterId: string;
    /**
     * List of returned results.
     * Default: [].
     */
    results?: DataRepositorySearchResult[];
} & Record<string, any>;
//# sourceMappingURL=data-repository-per-filter-search-result.d.ts.map