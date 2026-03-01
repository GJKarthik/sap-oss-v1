import { type CustomRequestConfig } from '@sap-ai-sdk/core';
import { type ModelDeployment } from '@sap-ai-sdk/ai-api/internal.js';
import { AzureOpenAiEmbeddingResponse } from './azure-openai-embedding-response.js';
import { type AzureOpenAiEmbeddingModel } from './model-types.js';
import type { AzureOpenAiEmbeddingParameters } from './azure-openai-embedding-types.js';
import type { HttpDestinationOrFetchOptions } from '@sap-cloud-sdk/connectivity';
/**
 * Azure OpenAI client for embeddings.
 */
export declare class AzureOpenAiEmbeddingClient {
    private modelDeployment;
    private destination?;
    /**
     * Creates an instance of the Azure OpenAI embedding client.
     * @param modelDeployment - This configuration is used to retrieve a deployment. Depending on the configuration use either the given deployment ID or the model name to retrieve matching deployments. If model and deployment ID are given, the model is verified against the deployment.
     */
    constructor(modelDeployment: ModelDeployment<AzureOpenAiEmbeddingModel>, destination?: HttpDestinationOrFetchOptions | undefined);
    /**
     * Creates an embedding vector representing the given text.
     * @param request - Request containing embedding input parameters.
     * @param requestConfig - The request configuration.
     * @returns The completion result.
     */
    run(request: AzureOpenAiEmbeddingParameters, requestConfig?: CustomRequestConfig): Promise<AzureOpenAiEmbeddingResponse>;
}
//# sourceMappingURL=azure-openai-embedding-client.d.ts.map