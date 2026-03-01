import type { VectorDocumentKeyValueListPair } from './vector-document-key-value-list-pair.js';
import type { VectorChunk } from './vector-chunk.js';
/**
 * Representation of the 'DocumentOutput' schema.
 */
export type DocumentOutput = {
    /**
     * Format: "uuid".
     */
    id: string;
    /**
     * Default: [].
     */
    metadata?: VectorDocumentKeyValueListPair[];
    chunks: VectorChunk[];
} & Record<string, any>;
//# sourceMappingURL=document-output.d.ts.map