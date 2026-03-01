import type { KeyValueListPair } from './key-value-list-pair.js';
/**
 * Representation of the 'Chunk' schema.
 */
export type Chunk = {
    id: string;
    content: string;
    /**
     * Default: [].
     */
    metadata?: KeyValueListPair[];
} & Record<string, any>;
//# sourceMappingURL=chunk.d.ts.map