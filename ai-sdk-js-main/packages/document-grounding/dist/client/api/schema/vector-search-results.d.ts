import type { VectorPerFilterSearchResult } from './vector-per-filter-search-result.js';
/**
 * Representation of the 'VectorSearchResults' schema.
 */
export type VectorSearchResults = {
    /**
     * List of returned results.
     */
    results: VectorPerFilterSearchResult[];
} & Record<string, any>;
//# sourceMappingURL=vector-search-results.d.ts.map