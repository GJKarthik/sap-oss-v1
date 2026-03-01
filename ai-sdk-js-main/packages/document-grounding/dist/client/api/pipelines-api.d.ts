import { OpenApiRequestBuilder } from '@sap-ai-sdk/core';
import type { GetPipelines, CreatePipeline, PipelineId, GetPipeline, PatchPipeline, GetPipelineStatus, SearchPipeline, SearchPipelinesResponse, GetPipelineExecutions, GetPipelineExecutionById, DocumentsStatusResponse, PipelineDocumentResponse, ManualPipelineTrigger } from './schema/index.js';
/**
 * Representation of the 'PipelinesApi'.
 * This API is part of the 'api' service.
 */
export declare const PipelinesApi: {
    _defaultBasePath: string;
    /**
     * Get all pipelines
     * @param queryParameters - Object containing the following keys: $top, $skip, $count.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getAllPipelines: (queryParameters: {
        $top?: number;
        $skip?: number;
        $count?: boolean;
    }, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<GetPipelines>;
    /**
     * Create a pipeline
     * @param body - Request body.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    createPipeline: (body: CreatePipeline, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<PipelineId>;
    /**
     * Get details of a pipeline by pipeline id
     * @param pipelineId - The ID of the pipeline to get.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getPipelineById: (pipelineId: string, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<GetPipeline>;
    /**
     * Patch a pipeline by pipeline id
     * @param pipelineId - The ID of the pipeline to patch.
     * @param body - Request body.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    patchPipelineById: (pipelineId: string, body: PatchPipeline, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<any>;
    /**
     * Delete a pipeline by pipeline id
     * @param pipelineId - The ID of the pipeline to delete.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    deletePipelineById: (pipelineId: string, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<any>;
    /**
     * Get pipeline status by pipeline id
     * @param pipelineId - The ID of the pipeline to get status.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getPipelineStatus: (pipelineId: string, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<GetPipelineStatus>;
    /**
     * Search for pipelines based on metadata
     * @param body - Request body.
     * @param queryParameters - Object containing the following keys: $top, $skip, $count.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    searchPipelinesByMetadata: (body: SearchPipeline, queryParameters: {
        $top?: number;
        $skip?: number;
        $count?: boolean;
    }, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<SearchPipelinesResponse>;
    /**
     * Retrieve all executions for a specific pipeline. Optionally, filter to get only the last execution.
     * @param pipelineId - The ID of the pipeline
     * @param queryParameters - Object containing the following keys: lastExecution, $top, $skip, $count.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getAllExecutionsForPipeline: (pipelineId: string, queryParameters: {
        lastExecution?: boolean;
        $top?: number;
        $skip?: number;
        $count?: boolean;
    }, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<GetPipelineExecutions>;
    /**
     * Retrieve details of a specific pipeline execution by its execution ID.
     * @param pipelineId - The ID of the pipeline
     * @param executionId - The ID of the execution
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getExecutionDetailsByIdForPipelineExecution: (pipelineId: string, executionId: string, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<GetPipelineExecutionById>;
    /**
     * Retrieve all documents associated with a specific pipeline execution. Optionally, filter the results using query parameters.
     * @param pipelineId - The ID of the pipeline
     * @param executionId - The ID of the execution
     * @param queryParameters - Object containing the following keys: $top, $skip, $count.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getDocumentsForPipelineExecution: (pipelineId: string, executionId: string, queryParameters: {
        $top?: number;
        $skip?: number;
        $count?: boolean;
    }, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<DocumentsStatusResponse>;
    /**
     * Retrieve details of a specific document associated with a pipeline execution.
     * @param pipelineId - The ID of the pipeline
     * @param executionId - The ID of the execution
     * @param documentId - The ID of the document to get.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getDocumentByIdForPipelineExecution: (pipelineId: string, executionId: string, documentId: string, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<PipelineDocumentResponse>;
    /**
     * Retrieve all documents associated with a specific pipeline. Optionally, filter the results using query parameters.
     * @param pipelineId - The ID of the pipeline to get.
     * @param queryParameters - Object containing the following keys: $top, $skip, $count.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getAllDocumentsForPipeline: (pipelineId: string, queryParameters: {
        $top?: number;
        $skip?: number;
        $count?: boolean;
    }, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<DocumentsStatusResponse>;
    /**
     * Retrieve details of a specific document associated with a pipeline.
     * @param pipelineId - The ID of the pipeline to get.
     * @param documentId - The ID of the document to get.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getDocumentByIdForPipeline: (pipelineId: string, documentId: string, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<PipelineDocumentResponse>;
    /**
     * Manually trigger a pipeline
     * @param body - Request body.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    manualTriggerPipeline: (body: ManualPipelineTrigger, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<any>;
};
//# sourceMappingURL=pipelines-api.d.ts.map