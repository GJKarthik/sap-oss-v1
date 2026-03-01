import type { EmbeddingConfig } from './embedding-config.js';
import type { VectorKeyValueListPair } from './vector-key-value-list-pair.js';
/**
 * A logical grouping of content.
 */
export type Collection = {
    title?: string | null;
    embeddingConfig: EmbeddingConfig;
    /**
     * Metadata attached to collection. Useful to restrict search to a subset of collections.
     * Default: [].
     */
    metadata?: VectorKeyValueListPair[];
    /**
     * Unique identifier of a collection.
     * Format: "uuid".
     */
    id: string;
} & Record<string, any>;
//# sourceMappingURL=collection.d.ts.map