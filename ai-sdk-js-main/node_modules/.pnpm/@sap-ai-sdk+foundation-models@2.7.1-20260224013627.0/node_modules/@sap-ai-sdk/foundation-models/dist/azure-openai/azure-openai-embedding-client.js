import { executeRequest } from '@sap-ai-sdk/core';
import { getFoundationModelDeploymentId, getResourceGroup } from '@sap-ai-sdk/ai-api/internal.js';
import { AzureOpenAiEmbeddingResponse } from './azure-openai-embedding-response.js';
import { apiVersion } from './model-types.js';
/**
 * Azure OpenAI client for embeddings.
 */
export class AzureOpenAiEmbeddingClient {
    modelDeployment;
    destination;
    /**
     * Creates an instance of the Azure OpenAI embedding client.
     * @param modelDeployment - This configuration is used to retrieve a deployment. Depending on the configuration use either the given deployment ID or the model name to retrieve matching deployments. If model and deployment ID are given, the model is verified against the deployment.
     */
    constructor(modelDeployment, destination) {
        this.modelDeployment = modelDeployment;
        this.destination = destination;
    }
    /**
     * Creates an embedding vector representing the given text.
     * @param request - Request containing embedding input parameters.
     * @param requestConfig - The request configuration.
     * @returns The completion result.
     */
    async run(request, requestConfig) {
        const deploymentId = await getFoundationModelDeploymentId(this.modelDeployment, 'azure-openai', this.destination);
        const resourceGroup = getResourceGroup(this.modelDeployment);
        const response = await executeRequest({
            url: `/inference/deployments/${deploymentId}/embeddings`,
            apiVersion,
            resourceGroup
        }, request, requestConfig, this.destination);
        return new AzureOpenAiEmbeddingResponse(response);
    }
}
//# sourceMappingURL=azure-openai-embedding-client.js.map