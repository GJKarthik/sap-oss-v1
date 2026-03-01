import { type CustomRequestConfig } from '@sap-ai-sdk/core';
import { type AzureOpenAiChatModel } from './model-types.js';
import { AzureOpenAiChatCompletionResponse } from './azure-openai-chat-completion-response.js';
import { AzureOpenAiChatCompletionStreamResponse } from './azure-openai-chat-completion-stream-response.js';
import type { AzureOpenAiChatCompletionParameters } from './azure-openai-chat-completion-types.js';
import type { ModelDeployment } from '@sap-ai-sdk/ai-api';
import type { AzureOpenAiChatCompletionStreamChunkResponse } from './azure-openai-chat-completion-stream-chunk-response.js';
import type { HttpDestinationOrFetchOptions } from '@sap-cloud-sdk/connectivity';
/**
 * Azure OpenAI client for chat completion.
 */
export declare class AzureOpenAiChatClient {
    private modelDeployment;
    private destination?;
    /**
     * Creates an instance of the Azure OpenAI chat client.
     * @param modelDeployment - This configuration is used to retrieve a deployment. Depending on the configuration use either the given deployment ID or the model name to retrieve matching deployments. If model and deployment ID are given, the model is verified against the deployment.
     * @param destination - The destination to use for the request.
     */
    constructor(modelDeployment: ModelDeployment<AzureOpenAiChatModel>, destination?: HttpDestinationOrFetchOptions | undefined);
    /**
     * Creates a completion for the chat messages.
     * @param request - Request containing chat completion input parameters.
     * @param requestConfig - The request configuration.
     * @returns The completion result.
     */
    run(request: AzureOpenAiChatCompletionParameters, requestConfig?: CustomRequestConfig): Promise<AzureOpenAiChatCompletionResponse>;
    /**
     * Creates a completion stream for the chat messages.
     * @param request - Request containing chat completion input parameters.
     * @param signal - The abort signal.
     * @param requestConfig - The request configuration.
     * @returns A response containing the chat completion stream.
     */
    stream(request: AzureOpenAiChatCompletionParameters, signal?: AbortSignal, requestConfig?: CustomRequestConfig): Promise<AzureOpenAiChatCompletionStreamResponse<AzureOpenAiChatCompletionStreamChunkResponse>>;
    private executeRequest;
    private createStream;
}
//# sourceMappingURL=azure-openai-chat-client.d.ts.map