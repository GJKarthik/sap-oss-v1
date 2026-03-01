import type { RetrievalSearchSelectOptionEnum } from './retrieval-search-select-option-enum.js';
/**
 * Representation of the 'RetrievalSearchDocumentKeyValueListPair' schema.
 */
export type RetrievalSearchDocumentKeyValueListPair = {
    /**
     * Max Length: 1024.
     */
    key: string;
    value: string[];
    /**
     * Select mode for search filters
     */
    selectMode?: RetrievalSearchSelectOptionEnum[];
} & Record<string, any>;
//# sourceMappingURL=retrieval-search-document-key-value-list-pair.d.ts.map