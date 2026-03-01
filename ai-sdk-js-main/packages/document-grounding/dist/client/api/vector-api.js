/*
 * Copyright (c) 2026 SAP SE or an SAP affiliate company. All rights reserved.
 *
 * This is a generated file powered by the SAP Cloud SDK for JavaScript.
 */
import { OpenApiRequestBuilder } from '@sap-ai-sdk/core';
/**
 * Representation of the 'VectorApi'.
 * This API is part of the 'api' service.
 */
export const VectorApi = {
    _defaultBasePath: '/lm/document-grounding',
    /**
     * Gets a list of collections.
     * @param queryParameters - Object containing the following keys: $top, $skip, $count.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getAllCollections: (queryParameters, headerParameters) => new OpenApiRequestBuilder('get', '/vector/collections', {
        queryParameters,
        headerParameters
    }, VectorApi._defaultBasePath),
    /**
     * Creates a collection. This operation is asynchronous. Poll the collection resource and check the status field to understand creation status.
     * @param body - Request body.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    createCollection: (body, headerParameters) => new OpenApiRequestBuilder('post', '/vector/collections', {
        body,
        headerParameters
    }, VectorApi._defaultBasePath),
    /**
     * Gets a specific collection by ID.
     * @param collectionId - Collection ID
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getCollectionById: (collectionId, headerParameters) => new OpenApiRequestBuilder('get', '/vector/collections/{collectionId}', {
        pathParameters: { collectionId },
        headerParameters
    }, VectorApi._defaultBasePath),
    /**
     * Deletes a specific collection by ID. This operation is asynchronous. Poll the collection for a 404 status code.
     * @param collectionId - Collection ID
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    deleteCollectionById: (collectionId, headerParameters) => new OpenApiRequestBuilder('delete', '/vector/collections/{collectionId}', {
        pathParameters: { collectionId },
        headerParameters
    }, VectorApi._defaultBasePath),
    /**
     * Gets a specific document in a collection by ID.
     * @param collectionId - Collection ID
     * @param documentId - Document ID
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getDocumentById: (collectionId, documentId, headerParameters) => new OpenApiRequestBuilder('get', '/vector/collections/{collectionId}/documents/{documentId}', {
        pathParameters: { collectionId, documentId },
        headerParameters
    }, VectorApi._defaultBasePath),
    /**
     * Deletes a specific document of a collection.
     * @param collectionId - Collection ID
     * @param documentId - Document ID
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    deleteDocumentById: (collectionId, documentId, headerParameters) => new OpenApiRequestBuilder('delete', '/vector/collections/{collectionId}/documents/{documentId}', {
        pathParameters: { collectionId, documentId },
        headerParameters
    }, VectorApi._defaultBasePath),
    /**
     * Gets a list of documents of a collection.
     * @param collectionId - Collection ID
     * @param queryParameters - Object containing the following keys: $top, $skip, $count.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getAllDocuments: (collectionId, queryParameters, headerParameters) => new OpenApiRequestBuilder('get', '/vector/collections/{collectionId}/documents', {
        pathParameters: { collectionId },
        queryParameters,
        headerParameters
    }, VectorApi._defaultBasePath),
    /**
     * Create and stores one or multiple documents into a collection. If omitted, 'id' will be auto-generated.
     * @param collectionId - Collection ID
     * @param body - Request body.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    createDocuments: (collectionId, body, headerParameters) => new OpenApiRequestBuilder('post', '/vector/collections/{collectionId}/documents', {
        pathParameters: { collectionId },
        body,
        headerParameters
    }, VectorApi._defaultBasePath),
    /**
     * Upserts the data of multiple documents into a collection.
     * @param collectionId - Collection ID
     * @param body - Request body.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    updateDocuments: (collectionId, body, headerParameters) => new OpenApiRequestBuilder('patch', '/vector/collections/{collectionId}/documents', {
        pathParameters: { collectionId },
        body,
        headerParameters
    }, VectorApi._defaultBasePath),
    /**
     * Search chunks
     * @param body - Request body.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    search: (body, headerParameters) => new OpenApiRequestBuilder('post', '/vector/search', {
        body,
        headerParameters
    }, VectorApi._defaultBasePath),
    /**
     * Gets a specific collection status from monitor by ID.
     * @param id - Collection ID
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getCollectionCreationStatus: (id, headerParameters) => new OpenApiRequestBuilder('get', '/vector/collections/{id}/creationStatus', {
        pathParameters: { id },
        headerParameters
    }, VectorApi._defaultBasePath),
    /**
     * Gets a specific collection status from monitor by ID.
     * @param id - Collection ID
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getCollectionDeletionStatus: (id, headerParameters) => new OpenApiRequestBuilder('get', '/vector/collections/{id}/deletionStatus', {
        pathParameters: { id },
        headerParameters
    }, VectorApi._defaultBasePath)
};
//# sourceMappingURL=vector-api.js.map