import type { VectorSearchFilter } from './vector-search-filter.js';
/**
 * Representation of the 'TextSearchRequest' schema.
 */
export type TextSearchRequest = {
    /**
     * Query string
     * Max Length: 2000.
     * Min Length: 1.
     */
    query: string;
    filters: VectorSearchFilter[];
} & Record<string, any>;
//# sourceMappingURL=text-search-request.d.ts.map