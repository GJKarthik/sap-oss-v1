import type { RetrievalKeyValueListPair } from './retrieval-key-value-list-pair.js';
/**
 * Representation of the 'RetrievalChunk' schema.
 */
export type RetrievalChunk = {
    id: string;
    content: string;
    /**
     * Default: [].
     */
    metadata?: RetrievalKeyValueListPair[];
} & Record<string, any>;
//# sourceMappingURL=retrieval-chunk.d.ts.map