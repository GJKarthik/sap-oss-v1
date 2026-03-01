import type { IncludePathsArray } from './include-paths-array.js';
/**
 * Representation of the 'SharePointSiteDetail' schema.
 */
export type SharePointSiteDetail = {
    /**
     * @example "sharepoint-site-id"
     */
    id?: string;
    /**
     * @example "sharepoint-site-name"
     */
    name: string;
    includePaths?: IncludePathsArray;
} & Record<string, any>;
//# sourceMappingURL=share-point-site-detail.d.ts.map