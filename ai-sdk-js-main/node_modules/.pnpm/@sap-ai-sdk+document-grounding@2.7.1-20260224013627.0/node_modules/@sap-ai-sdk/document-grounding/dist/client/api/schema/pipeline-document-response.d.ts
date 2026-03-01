import type { DocumentStatus } from './document-status.js';
/**
 * Representation of the 'PipelineDocumentResponse' schema.
 */
export type PipelineDocumentResponse = {
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
} & Record<string, any>;
//# sourceMappingURL=pipeline-document-response.d.ts.map