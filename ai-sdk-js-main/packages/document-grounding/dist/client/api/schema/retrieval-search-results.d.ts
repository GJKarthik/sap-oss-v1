import type { RetrievalPerFilterSearchResult } from './retrieval-per-filter-search-result.js';
import type { RetrievalPerFilterSearchResultWithError } from './retrieval-per-filter-search-result-with-error.js';
/**
 * Representation of the 'RetrievalSearchResults' schema.
 */
export type RetrievalSearchResults = {
    /**
     * List of returned results.
     */
    results: (RetrievalPerFilterSearchResult | RetrievalPerFilterSearchResultWithError)[];
} & Record<string, any>;
//# sourceMappingURL=retrieval-search-results.d.ts.map