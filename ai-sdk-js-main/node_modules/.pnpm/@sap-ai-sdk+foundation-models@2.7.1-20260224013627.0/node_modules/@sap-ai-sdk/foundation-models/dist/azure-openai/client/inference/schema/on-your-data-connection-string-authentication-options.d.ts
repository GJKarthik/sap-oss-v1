/**
 * The authentication options for Azure OpenAI On Your Data when using a connection string.
 */
export type AzureOpenAiOnYourDataConnectionStringAuthenticationOptions = {
    type: string;
} & {
    /**
     * The connection string to use for authentication.
     */
    connection_string: string;
} & Record<string, any>;
//# sourceMappingURL=on-your-data-connection-string-authentication-options.d.ts.map