import type { RetrievalDocumentKeyValueListPair } from './retrieval-document-key-value-list-pair.js';
import type { RetrievalChunk } from './retrieval-chunk.js';
/**
 * Representation of the 'Document' schema.
 */
export type Document = {
    id: string;
    /**
     * Default: [].
     */
    metadata?: RetrievalDocumentKeyValueListPair[];
    chunks: RetrievalChunk[];
} & Record<string, any>;
//# sourceMappingURL=document.d.ts.map