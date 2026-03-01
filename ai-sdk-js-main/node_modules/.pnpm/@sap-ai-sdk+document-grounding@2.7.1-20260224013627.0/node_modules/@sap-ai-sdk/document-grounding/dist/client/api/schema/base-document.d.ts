import type { TextOnlyBaseChunk } from './text-only-base-chunk.js';
import type { VectorDocumentKeyValueListPair } from './vector-document-key-value-list-pair.js';
/**
 * Base class for documents, document requests and responses.
 */
export type BaseDocument = {
    chunks: TextOnlyBaseChunk[];
    metadata: VectorDocumentKeyValueListPair[];
} & Record<string, any>;
//# sourceMappingURL=base-document.d.ts.map