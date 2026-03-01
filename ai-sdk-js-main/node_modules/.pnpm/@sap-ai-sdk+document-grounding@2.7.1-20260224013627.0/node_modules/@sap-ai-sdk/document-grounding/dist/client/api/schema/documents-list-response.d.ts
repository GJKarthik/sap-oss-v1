import type { DocumentWithoutChunks } from './document-without-chunks.js';
/**
 * A response containing documents created or updated, retrieved from the server.
 */
export type DocumentsListResponse = {
    documents: DocumentWithoutChunks[];
} & Record<string, any>;
//# sourceMappingURL=documents-list-response.d.ts.map