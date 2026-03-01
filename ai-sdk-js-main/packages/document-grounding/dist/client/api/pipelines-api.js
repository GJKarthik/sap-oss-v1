/*
 * Copyright (c) 2026 SAP SE or an SAP affiliate company. All rights reserved.
 *
 * This is a generated file powered by the SAP Cloud SDK for JavaScript.
 */
import { OpenApiRequestBuilder } from '@sap-ai-sdk/core';
/**
 * Representation of the 'PipelinesApi'.
 * This API is part of the 'api' service.
 */
export const PipelinesApi = {
    _defaultBasePath: '/lm/document-grounding',
    /**
     * Get all pipelines
     * @param queryParameters - Object containing the following keys: $top, $skip, $count.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getAllPipelines: (queryParameters, headerParameters) => new OpenApiRequestBuilder('get', '/pipelines', {
        queryParameters,
        headerParameters
    }, PipelinesApi._defaultBasePath),
    /**
     * Create a pipeline
     * @param body - Request body.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    createPipeline: (body, headerParameters) => new OpenApiRequestBuilder('post', '/pipelines', {
        body,
        headerParameters
    }, PipelinesApi._defaultBasePath),
    /**
     * Get details of a pipeline by pipeline id
     * @param pipelineId - The ID of the pipeline to get.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getPipelineById: (pipelineId, headerParameters) => new OpenApiRequestBuilder('get', '/pipelines/{pipelineId}', {
        pathParameters: { pipelineId },
        headerParameters
    }, PipelinesApi._defaultBasePath),
    /**
     * Patch a pipeline by pipeline id
     * @param pipelineId - The ID of the pipeline to patch.
     * @param body - Request body.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    patchPipelineById: (pipelineId, body, headerParameters) => new OpenApiRequestBuilder('patch', '/pipelines/{pipelineId}', {
        pathParameters: { pipelineId },
        body,
        headerParameters
    }, PipelinesApi._defaultBasePath),
    /**
     * Delete a pipeline by pipeline id
     * @param pipelineId - The ID of the pipeline to delete.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    deletePipelineById: (pipelineId, headerParameters) => new OpenApiRequestBuilder('delete', '/pipelines/{pipelineId}', {
        pathParameters: { pipelineId },
        headerParameters
    }, PipelinesApi._defaultBasePath),
    /**
     * Get pipeline status by pipeline id
     * @param pipelineId - The ID of the pipeline to get status.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getPipelineStatus: (pipelineId, headerParameters) => new OpenApiRequestBuilder('get', '/pipelines/{pipelineId}/status', {
        pathParameters: { pipelineId },
        headerParameters
    }, PipelinesApi._defaultBasePath),
    /**
     * Search for pipelines based on metadata
     * @param body - Request body.
     * @param queryParameters - Object containing the following keys: $top, $skip, $count.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    searchPipelinesByMetadata: (body, queryParameters, headerParameters) => new OpenApiRequestBuilder('post', '/pipelines/search', {
        body,
        queryParameters,
        headerParameters
    }, PipelinesApi._defaultBasePath),
    /**
     * Retrieve all executions for a specific pipeline. Optionally, filter to get only the last execution.
     * @param pipelineId - The ID of the pipeline
     * @param queryParameters - Object containing the following keys: lastExecution, $top, $skip, $count.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getAllExecutionsForPipeline: (pipelineId, queryParameters, headerParameters) => new OpenApiRequestBuilder('get', '/pipelines/{pipelineId}/executions', {
        pathParameters: { pipelineId },
        queryParameters,
        headerParameters
    }, PipelinesApi._defaultBasePath),
    /**
     * Retrieve details of a specific pipeline execution by its execution ID.
     * @param pipelineId - The ID of the pipeline
     * @param executionId - The ID of the execution
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getExecutionDetailsByIdForPipelineExecution: (pipelineId, executionId, headerParameters) => new OpenApiRequestBuilder('get', '/pipelines/{pipelineId}/executions/{executionId}', {
        pathParameters: { pipelineId, executionId },
        headerParameters
    }, PipelinesApi._defaultBasePath),
    /**
     * Retrieve all documents associated with a specific pipeline execution. Optionally, filter the results using query parameters.
     * @param pipelineId - The ID of the pipeline
     * @param executionId - The ID of the execution
     * @param queryParameters - Object containing the following keys: $top, $skip, $count.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getDocumentsForPipelineExecution: (pipelineId, executionId, queryParameters, headerParameters) => new OpenApiRequestBuilder('get', '/pipelines/{pipelineId}/executions/{executionId}/documents', {
        pathParameters: { pipelineId, executionId },
        queryParameters,
        headerParameters
    }, PipelinesApi._defaultBasePath),
    /**
     * Retrieve details of a specific document associated with a pipeline execution.
     * @param pipelineId - The ID of the pipeline
     * @param executionId - The ID of the execution
     * @param documentId - The ID of the document to get.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getDocumentByIdForPipelineExecution: (pipelineId, executionId, documentId, headerParameters) => new OpenApiRequestBuilder('get', '/pipelines/{pipelineId}/executions/{executionId}/documents/{documentId}', {
        pathParameters: { pipelineId, executionId, documentId },
        headerParameters
    }, PipelinesApi._defaultBasePath),
    /**
     * Retrieve all documents associated with a specific pipeline. Optionally, filter the results using query parameters.
     * @param pipelineId - The ID of the pipeline to get.
     * @param queryParameters - Object containing the following keys: $top, $skip, $count.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getAllDocumentsForPipeline: (pipelineId, queryParameters, headerParameters) => new OpenApiRequestBuilder('get', '/pipelines/{pipelineId}/documents', {
        pathParameters: { pipelineId },
        queryParameters,
        headerParameters
    }, PipelinesApi._defaultBasePath),
    /**
     * Retrieve details of a specific document associated with a pipeline.
     * @param pipelineId - The ID of the pipeline to get.
     * @param documentId - The ID of the document to get.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getDocumentByIdForPipeline: (pipelineId, documentId, headerParameters) => new OpenApiRequestBuilder('get', '/pipelines/{pipelineId}/documents/{documentId}', {
        pathParameters: { pipelineId, documentId },
        headerParameters
    }, PipelinesApi._defaultBasePath),
    /**
     * Manually trigger a pipeline
     * @param body - Request body.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    manualTriggerPipeline: (body, headerParameters) => new OpenApiRequestBuilder('post', '/pipelines/trigger', {
        body,
        headerParameters
    }, PipelinesApi._defaultBasePath)
};
//# sourceMappingURL=pipelines-api.js.map