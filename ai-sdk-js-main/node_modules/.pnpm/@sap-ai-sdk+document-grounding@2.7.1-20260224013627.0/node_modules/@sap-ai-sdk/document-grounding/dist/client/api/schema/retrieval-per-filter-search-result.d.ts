import type { RetrievalDataRepositorySearchResult } from './retrieval-data-repository-search-result.js';
/**
 * Representation of the 'RetrievalPerFilterSearchResult' schema.
 */
export type RetrievalPerFilterSearchResult = {
    filterId: string;
    /**
     * List of returned results.
     * Default: [].
     */
    results?: RetrievalDataRepositorySearchResult[];
} & Record<string, any>;
//# sourceMappingURL=retrieval-per-filter-search-result.d.ts.map