import type { TextOnlyBaseChunk } from './text-only-base-chunk.js';
import type { VectorDocumentKeyValueListPair } from './vector-document-key-value-list-pair.js';
/**
 * A single document stored in a collection by ID.
 */
export type DocumentInput = {
    chunks: TextOnlyBaseChunk[];
    metadata: VectorDocumentKeyValueListPair[];
    /**
     * Unique identifier of a document.
     * Format: "uuid".
     */
    id: string;
} & Record<string, any>;
//# sourceMappingURL=document-input.d.ts.map