import type { VectorKeyValueListPair } from './vector-key-value-list-pair.js';
import type { DocumentOutput } from './document-output.js';
/**
 * Representation of the 'DocumentsChunk' schema.
 */
export type DocumentsChunk = {
    /**
     * Format: "uuid".
     */
    id: string;
    title: string;
    /**
     * Default: [].
     */
    metadata?: VectorKeyValueListPair[];
    documents: DocumentOutput[];
} & Record<string, any>;
//# sourceMappingURL=documents-chunk.d.ts.map