import type { EmbeddingConfig } from './embedding-config.js';
import type { VectorKeyValueListPair } from './vector-key-value-list-pair.js';
/**
 * A request for creating a new, single collection.
 */
export type CollectionRequest = {
    title?: string | null;
    embeddingConfig: EmbeddingConfig;
    /**
     * Metadata attached to collection. Useful to restrict search to a subset of collections.
     * Default: [].
     */
    metadata?: VectorKeyValueListPair[];
} & Record<string, any>;
//# sourceMappingURL=collection-request.d.ts.map