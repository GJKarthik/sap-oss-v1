/**
 * Representation of the 'AzureOpenAiChatCompletionRequestFunctionMessage' schema.
 * @deprecated
 */
export type AzureOpenAiChatCompletionRequestFunctionMessage = {
    /**
     * The role of the messages author, in this case `function`.
     */
    role: 'function';
    /**
     * The contents of the function message.
     */
    content: string | null;
    /**
     * The name of the function to call.
     */
    name: string;
} & Record<string, any>;
//# sourceMappingURL=chat-completion-request-function-message.d.ts.map