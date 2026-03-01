/**
 * Specifying a particular function via `{"name": "my_function"}` forces the model to call that function.
 *
 */
export type AzureOpenAiChatCompletionFunctionCallOption = {
    /**
     * The name of the function to call.
     */
    name: string;
} & Record<string, any>;
//# sourceMappingURL=chat-completion-function-call-option.d.ts.map