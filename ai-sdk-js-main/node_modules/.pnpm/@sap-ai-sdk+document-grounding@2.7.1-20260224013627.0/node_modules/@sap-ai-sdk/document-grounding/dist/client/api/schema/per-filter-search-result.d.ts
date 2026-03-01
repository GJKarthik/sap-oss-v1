import type { DocumentsChunk } from './documents-chunk.js';
/**
 * Representation of the 'PerFilterSearchResult' schema.
 */
export type PerFilterSearchResult = {
    filterId: string;
    results: DocumentsChunk[];
} & Record<string, any>;
//# sourceMappingURL=per-filter-search-result.d.ts.map