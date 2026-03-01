/**
 * Representation of the 'RetrievalDocumentKeyValueListPair' schema.
 */
export type RetrievalDocumentKeyValueListPair = {
    /**
     * Max Length: 1024.
     */
    key: string;
    value: string[];
    /**
     * Default match mode for search filters
     * Default: "ANY".
     */
    matchMode?: 'ANY' | 'ALL' | any | null;
} & Record<string, any>;
//# sourceMappingURL=retrieval-document-key-value-list-pair.d.ts.map