/**
 * The authentication options for Azure OpenAI On Your Data when using a user-assigned managed identity.
 */
export type AzureOpenAiOnYourDataUserAssignedManagedIdentityAuthenticationOptions = {
    type: string;
} & {
    /**
     * The resource ID of the user-assigned managed identity to use for authentication.
     */
    managed_identity_resource_id: string;
} & Record<string, any>;
//# sourceMappingURL=on-your-data-user-assigned-managed-identity-authentication-options.d.ts.map