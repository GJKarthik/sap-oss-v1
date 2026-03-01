import { OpenApiRequestBuilder } from '@sap-ai-sdk/core';
import type { CollectionsListResponse, CollectionRequest, Collection, DocumentResponse, Documents, DocumentCreateRequest, DocumentsListResponse, DocumentUpdateRequest, TextSearchRequest, VectorSearchResults, CollectionCreatedResponse, CollectionPendingResponse, CollectionDeletedResponse } from './schema/index.js';
/**
 * Representation of the 'VectorApi'.
 * This API is part of the 'api' service.
 */
export declare const VectorApi: {
    _defaultBasePath: string;
    /**
     * Gets a list of collections.
     * @param queryParameters - Object containing the following keys: $top, $skip, $count.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getAllCollections: (queryParameters: {
        $top?: number;
        $skip?: number;
        $count?: boolean;
    }, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<CollectionsListResponse>;
    /**
     * Creates a collection. This operation is asynchronous. Poll the collection resource and check the status field to understand creation status.
     * @param body - Request body.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    createCollection: (body: CollectionRequest, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<any>;
    /**
     * Gets a specific collection by ID.
     * @param collectionId - Collection ID
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getCollectionById: (collectionId: string, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<Collection>;
    /**
     * Deletes a specific collection by ID. This operation is asynchronous. Poll the collection for a 404 status code.
     * @param collectionId - Collection ID
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    deleteCollectionById: (collectionId: string, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<any>;
    /**
     * Gets a specific document in a collection by ID.
     * @param collectionId - Collection ID
     * @param documentId - Document ID
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getDocumentById: (collectionId: string, documentId: string, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<DocumentResponse>;
    /**
     * Deletes a specific document of a collection.
     * @param collectionId - Collection ID
     * @param documentId - Document ID
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    deleteDocumentById: (collectionId: string, documentId: string, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<any>;
    /**
     * Gets a list of documents of a collection.
     * @param collectionId - Collection ID
     * @param queryParameters - Object containing the following keys: $top, $skip, $count.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getAllDocuments: (collectionId: string, queryParameters: {
        $top?: number;
        $skip?: number;
        $count?: boolean;
    }, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<Documents>;
    /**
     * Create and stores one or multiple documents into a collection. If omitted, 'id' will be auto-generated.
     * @param collectionId - Collection ID
     * @param body - Request body.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    createDocuments: (collectionId: string, body: DocumentCreateRequest, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<DocumentsListResponse>;
    /**
     * Upserts the data of multiple documents into a collection.
     * @param collectionId - Collection ID
     * @param body - Request body.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    updateDocuments: (collectionId: string, body: DocumentUpdateRequest, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<DocumentsListResponse>;
    /**
     * Search chunks
     * @param body - Request body.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    search: (body: TextSearchRequest, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<VectorSearchResults>;
    /**
     * Gets a specific collection status from monitor by ID.
     * @param id - Collection ID
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getCollectionCreationStatus: (id: string, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<CollectionCreatedResponse | CollectionPendingResponse>;
    /**
     * Gets a specific collection status from monitor by ID.
     * @param id - Collection ID
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getCollectionDeletionStatus: (id: string, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<CollectionPendingResponse | CollectionDeletedResponse>;
};
//# sourceMappingURL=vector-api.d.ts.map