import type { VectorKeyValueListPair } from './vector-key-value-list-pair.js';
/**
 * Representation of the 'VectorChunk' schema.
 */
export type VectorChunk = {
    id: string;
    content: string;
    /**
     * Default: [].
     */
    metadata?: VectorKeyValueListPair[];
} & Record<string, any>;
//# sourceMappingURL=vector-chunk.d.ts.map