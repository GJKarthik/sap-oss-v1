import { OpenApiRequestBuilder } from '@sap-ai-sdk/core';
import type { DataRepositories, DataRepository, RetrievalSearchInput, RetrievalSearchResults } from './schema/index.js';
/**
 * Representation of the 'RetrievalApi'.
 * This API is part of the 'api' service.
 */
export declare const RetrievalApi: {
    _defaultBasePath: string;
    /**
     * List all Data Repositories
     * @param queryParameters - Object containing the following keys: $top, $skip, $count.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getDataRepositories: (queryParameters: {
        $top?: number;
        $skip?: number;
        $count?: boolean;
    }, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<DataRepositories>;
    /**
     * List data repository by id
     * @param repositoryId - Repository ID
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    getDataRepositoryById: (repositoryId: string, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<DataRepository>;
    /**
     * Retrieve relevant content given a query string.
     * @param body - Request body.
     * @param headerParameters - Object containing the following keys: AI-Resource-Group.
     * @returns The request builder, use the `execute()` method to trigger the request.
     */
    search: (body: RetrievalSearchInput, headerParameters: {
        "AI-Resource-Group": string;
    }) => OpenApiRequestBuilder<RetrievalSearchResults>;
};
//# sourceMappingURL=retrieval-api.d.ts.map