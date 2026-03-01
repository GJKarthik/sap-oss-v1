import type { DocumentWithoutChunks } from './document-without-chunks.js';
/**
 * A response containing documents retrieved from the server.
 */
export type Documents = {
    count?: number;
    resources: DocumentWithoutChunks[];
} & Record<string, any>;
//# sourceMappingURL=documents.d.ts.map