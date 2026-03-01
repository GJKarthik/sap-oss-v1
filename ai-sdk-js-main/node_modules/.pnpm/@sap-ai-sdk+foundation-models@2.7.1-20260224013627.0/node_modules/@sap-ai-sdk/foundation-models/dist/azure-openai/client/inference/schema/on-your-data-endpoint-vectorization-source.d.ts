import type { AzureOpenAiOnYourDataApiKeyAuthenticationOptions } from './on-your-data-api-key-authentication-options.js';
/**
 * The details of a a vectorization source, used by Azure OpenAI On Your Data when applying vector search, that is based
 * on a public Azure OpenAI endpoint call for embeddings.
 */
export type AzureOpenAiOnYourDataEndpointVectorizationSource = {
    type: string;
} & {
    authentication: AzureOpenAiOnYourDataApiKeyAuthenticationOptions;
    /**
     * Specifies the endpoint to use for vectorization. This endpoint must be in the same Azure OpenAI resource, but On Your Data will use this endpoint via an internal call rather than a public one, which enables vector search even in private networks.
     * Format: "uri".
     */
    endpoint: string;
} & Record<string, any>;
//# sourceMappingURL=on-your-data-endpoint-vectorization-source.d.ts.map