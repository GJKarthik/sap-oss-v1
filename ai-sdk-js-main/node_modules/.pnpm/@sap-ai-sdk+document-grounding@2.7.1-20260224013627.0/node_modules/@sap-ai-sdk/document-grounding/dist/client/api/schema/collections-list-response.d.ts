import type { Collection } from './collection.js';
/**
 * A response containing collections retrieved from the server.
 */
export type CollectionsListResponse = {
    count?: number;
    resources: Collection[];
} & Record<string, any>;
//# sourceMappingURL=collections-list-response.d.ts.map