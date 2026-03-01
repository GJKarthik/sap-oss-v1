import type { VectorKeyValueListPair } from './vector-key-value-list-pair.js';
/**
 * Representation of the 'TextOnlyBaseChunk' schema.
 */
export type TextOnlyBaseChunk = {
    content: string;
    metadata: VectorKeyValueListPair[];
} & Record<string, any>;
//# sourceMappingURL=text-only-base-chunk.d.ts.map