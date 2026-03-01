import type { TextOnlyBaseChunk } from './text-only-base-chunk.js';
import type { VectorDocumentKeyValueListPair } from './vector-document-key-value-list-pair.js';
/**
 * A response containing information about a newly created, single document.
 */
export type DocumentResponse = {
    chunks: TextOnlyBaseChunk[];
    metadata: VectorDocumentKeyValueListPair[];
    /**
     * Unique identifier of a document.
     * Format: "uuid".
     */
    id: string;
} & Record<string, any>;
//# sourceMappingURL=document-response.d.ts.map