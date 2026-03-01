/**
 * Representation of the 'RetrievalSearchConfiguration' schema.
 */
export type RetrievalSearchConfiguration = {
    /**
     * Maximum number of chunks to be returned. Cannot be used with 'maxDocumentCount'.
     */
    maxChunkCount?: number | null;
    /**
     * [Only supports 'vector' dataRepositoryType] - Maximum number of documents to be returned. Cannot be used with 'maxChunkCount'. If maxDocumentCount is given, then only one chunk per document is returned.
     */
    maxDocumentCount?: number | null;
} & Record<string, any>;
//# sourceMappingURL=retrieval-search-configuration.d.ts.map