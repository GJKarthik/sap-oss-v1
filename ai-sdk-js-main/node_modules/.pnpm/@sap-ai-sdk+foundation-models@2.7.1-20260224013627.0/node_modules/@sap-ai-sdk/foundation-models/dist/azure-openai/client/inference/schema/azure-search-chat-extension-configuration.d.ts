import type { AzureOpenAiAzureSearchChatExtensionParameters } from './azure-search-chat-extension-parameters.js';
/**
 * A specific representation of configurable options for Azure Search when using it as an Azure OpenAI chat
 * extension.
 */
export type AzureOpenAiAzureSearchChatExtensionConfiguration = {
    type: string;
} & {
    parameters: AzureOpenAiAzureSearchChatExtensionParameters;
} & Record<string, any>;
//# sourceMappingURL=azure-search-chat-extension-configuration.d.ts.map