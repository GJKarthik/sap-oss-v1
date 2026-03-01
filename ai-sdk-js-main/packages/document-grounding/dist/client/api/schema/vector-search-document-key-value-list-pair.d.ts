import type { VectorSearchSelectOptionEnum } from './vector-search-select-option-enum.js';
/**
 * Representation of the 'VectorSearchDocumentKeyValueListPair' schema.
 */
export type VectorSearchDocumentKeyValueListPair = {
    /**
     * Max Length: 1024.
     */
    key: string;
    value: string[];
    /**
     * Select mode for search filters
     */
    selectMode?: VectorSearchSelectOptionEnum[];
} & Record<string, any>;
//# sourceMappingURL=vector-search-document-key-value-list-pair.d.ts.map