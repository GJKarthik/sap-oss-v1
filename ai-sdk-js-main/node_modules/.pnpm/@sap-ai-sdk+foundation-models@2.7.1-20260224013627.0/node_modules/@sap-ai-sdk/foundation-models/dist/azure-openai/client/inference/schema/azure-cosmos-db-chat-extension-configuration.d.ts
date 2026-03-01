import type { AzureOpenAiAzureCosmosDBChatExtensionParameters } from './azure-cosmos-db-chat-extension-parameters.js';
/**
 * A specific representation of configurable options for Azure Cosmos DB when using it as an Azure OpenAI chat
 * extension.
 */
export type AzureOpenAiAzureCosmosDBChatExtensionConfiguration = {
    type: string;
} & {
    parameters: AzureOpenAiAzureCosmosDBChatExtensionParameters;
} & Record<string, any>;
//# sourceMappingURL=azure-cosmos-db-chat-extension-configuration.d.ts.map