import type { DocumentStatus } from './document-status.js';
/**
 * Representation of the 'DocumentsStatusResponse' schema.
 */
export type DocumentsStatusResponse = {
    /**
     * @example 1
     */
    count?: number;
    resources?: ({
        /**
         * @example "uuid"
         */
        id?: string;
        status?: DocumentStatus;
        /**
         * @example "location"
         */
        viewLocation?: string | null;
        /**
         * @example "location"
         */
        downloadLocation?: string | null;
        absoluteUrl?: string | null;
        title?: string | null;
        metadataId?: string | null;
        /**
         * @example "2024-02-15T12:45:00Z"
         */
        createdTimestamp?: string;
        /**
         * @example "2024-02-15T12:45:00Z"
         */
        lastUpdatedTimestamp?: string;
    } & Record<string, any>)[];
} & Record<string, any>;
//# sourceMappingURL=documents-status-response.d.ts.map