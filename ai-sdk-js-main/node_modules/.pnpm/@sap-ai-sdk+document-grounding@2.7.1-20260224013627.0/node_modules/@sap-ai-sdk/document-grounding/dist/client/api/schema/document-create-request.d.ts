import type { BaseDocument } from './base-document.js';
/**
 * A create request containing one or more new documents to create and store in a collection.
 */
export type DocumentCreateRequest = {
    documents: BaseDocument[];
} & Record<string, any>;
//# sourceMappingURL=document-create-request.d.ts.map