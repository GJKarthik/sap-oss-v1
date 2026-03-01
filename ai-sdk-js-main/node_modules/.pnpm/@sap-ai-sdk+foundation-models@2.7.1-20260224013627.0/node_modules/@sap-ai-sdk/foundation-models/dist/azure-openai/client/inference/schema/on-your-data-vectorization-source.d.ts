import type { AzureOpenAiOnYourDataEndpointVectorizationSource } from './on-your-data-endpoint-vectorization-source.js';
import type { AzureOpenAiOnYourDataDeploymentNameVectorizationSource } from './on-your-data-deployment-name-vectorization-source.js';
/**
 * An abstract representation of a vectorization source for Azure OpenAI On Your Data with vector search.
 */
export type AzureOpenAiOnYourDataVectorizationSource = ({
    type: 'endpoint';
} & AzureOpenAiOnYourDataEndpointVectorizationSource) | ({
    type: 'deployment_name';
} & AzureOpenAiOnYourDataDeploymentNameVectorizationSource);
//# sourceMappingURL=on-your-data-vectorization-source.d.ts.map