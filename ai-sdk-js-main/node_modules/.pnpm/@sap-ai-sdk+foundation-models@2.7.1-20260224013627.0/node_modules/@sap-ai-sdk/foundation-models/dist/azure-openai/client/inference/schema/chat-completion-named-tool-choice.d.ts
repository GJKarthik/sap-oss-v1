/**
 * Specifies a tool the model should use. Use to force the model to call a specific function.
 */
export type AzureOpenAiChatCompletionNamedToolChoice = {
    /**
     * The type of the tool. Currently, only `function` is supported.
     */
    type: 'function';
    function: {
        /**
         * The name of the function to call.
         */
        name: string;
    } & Record<string, any>;
} & Record<string, any>;
//# sourceMappingURL=chat-completion-named-tool-choice.d.ts.map