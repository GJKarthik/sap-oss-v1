import { OrchestrationStreamResponse } from './orchestration-stream-response.js';
import { OrchestrationResponse } from './orchestration-response.js';
import type { CustomRequestConfig } from '@sap-cloud-sdk/http-client';
import type { DeploymentIdConfig, ResourceGroupConfig } from '@sap-ai-sdk/ai-api/internal.js';
import type { OrchestrationModuleConfig, OrchestrationModuleConfigList, OrchestrationConfigRef, ChatCompletionRequest, StreamOptions } from './orchestration-types.js';
import type { OrchestrationStreamChunkResponse } from './orchestration-stream-chunk-response.js';
import type { HttpDestinationOrFetchOptions } from '@sap-cloud-sdk/connectivity';
/**
 * Get the orchestration client.
 */
export declare class OrchestrationClient {
    private config;
    private deploymentConfig?;
    private destination?;
    /**
     * Creates an instance of the orchestration client.
     * @param config - Orchestration configuration. Can be:
     * - An `OrchestrationModuleConfig` object for inline configuration
     * - An `OrchestrationModuleConfigList` array for module fallback (tries each config in order until one succeeds)
     * - A JSON string obtained from AI Launchpad
     * - An object of type`OrchestrationConfigRef` to reference a stored configuration by ID or name.
     * @param deploymentConfig - Deployment configuration.
     * @param destination - The destination to use for the request.
     */
    constructor(config: OrchestrationModuleConfig | OrchestrationModuleConfigList | string | OrchestrationConfigRef, deploymentConfig?: (ResourceGroupConfig | DeploymentIdConfig) | undefined, destination?: HttpDestinationOrFetchOptions | undefined);
    chatCompletion(request?: ChatCompletionRequest, requestConfig?: CustomRequestConfig): Promise<OrchestrationResponse>;
    stream(request?: ChatCompletionRequest, signal?: AbortSignal, options?: StreamOptions, requestConfig?: CustomRequestConfig): Promise<OrchestrationStreamResponse<OrchestrationStreamChunkResponse>>;
    private executeRequest;
    private createStreamResponse;
    /**
     * Validate if a string is valid JSON.
     * @param config - The JSON string to validate.
     */
    private validateJsonConfig;
    /**
     * Parse and merge templating into the config object.
     * @param config - The orchestration module configuration with templating either as object or string.
     * @returns The updated and merged orchestration module configuration.
     * @throws Error if the YAML parsing fails or if the parsed object does not conform to the expected schema.
     */
    private parseAndMergeTemplating;
    /**
     * Parse a single orchestration module config, handling YAML prompt templates.
     * @param config - The orchestration module configuration.
     * @returns The parsed configuration.
     */
    private parseTemplatingModule;
    /**
     * Parse and validate a list of orchestration module configs for fallback.
     * @param config - The array of configurations.
     * @returns The validated and parsed configuration list.
     * @throws {Error} If the array is empty or contains invalid elements.
     */
    private parseModuleConfigList;
}
//# sourceMappingURL=orchestration-client.d.ts.map