import type { IncludePathsArray } from './include-paths-array.js';
/**
 * Representation of the 'SharePointSite' schema.
 */
export type SharePointSite = {
    /**
     * @example "sharepoint-site-name"
     */
    name: string;
    includePaths?: IncludePathsArray;
} & Record<string, any>;
//# sourceMappingURL=share-point-site.d.ts.map