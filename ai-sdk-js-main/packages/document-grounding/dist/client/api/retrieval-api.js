/*
 * Copyright (c) 2026 SAP SE or an SAP affiliate company. All rights reserved.
 *
 * This is a generated file powered by the SAP Cloud SDK for JavaScript.
 */
import { OpenApiRequestBuilder } from '@sap-ai-sdk/core';
/**
 * Representation of the 'RetrievalApi'.
 * This API is part of the 'api' service.
 */
export const RetrievalApi = {
    _defaultBasePath: '/lm/document-grounding',
    /**
     * List all Data Repositories
     * @param queryParameters - Object containing the following keys: $top, $skip, $count.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getDataRepositories: (queryParameters, headerParameters) => new OpenApiRequestBuilder('get', '/retrieval/dataRepositories', {
        queryParameters,
        headerParameters
    }, RetrievalApi._defaultBasePath),
    /**
     * List data repository by id
     * @param repositoryId - Repository ID
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getDataRepositoryById: (repositoryId, headerParameters) => new OpenApiRequestBuilder('get', '/retrieval/dataRepositories/{repositoryId}', {
        pathParameters: { repositoryId },
        headerParameters
    }, RetrievalApi._defaultBasePath),
    /**
     * Retrieve relevant content given a query string.
     * @param body - Request body.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    search: (body, headerParameters) => new OpenApiRequestBuilder('post', '/retrieval/search', {
        body,
        headerParameters
    }, RetrievalApi._defaultBasePath)
};
//# sourceMappingURL=retrieval-api.js.map