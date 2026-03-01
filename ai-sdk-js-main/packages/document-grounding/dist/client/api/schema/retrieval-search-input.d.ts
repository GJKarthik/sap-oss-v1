import type { RetrievalSearchFilter } from './retrieval-search-filter.js';
/**
 * Representation of the 'RetrievalSearchInput' schema.
 */
export type RetrievalSearchInput = {
    /**
     * Query string
     * Min Length: 1.
     */
    query: string;
    filters: RetrievalSearchFilter[];
} & Record<string, any>;
//# sourceMappingURL=retrieval-search-input.d.ts.map