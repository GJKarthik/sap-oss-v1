import type { DocumentInput } from './document-input.js';
/**
 * An update request containing one or more documents to update existing documents in a collection by ID.
 */
export type DocumentUpdateRequest = {
    documents: DocumentInput[];
} & Record<string, any>;
//# sourceMappingURL=document-update-request.d.ts.map