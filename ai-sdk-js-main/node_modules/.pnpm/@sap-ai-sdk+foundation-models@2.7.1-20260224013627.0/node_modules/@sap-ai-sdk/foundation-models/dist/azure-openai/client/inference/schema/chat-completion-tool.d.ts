import type { AzureOpenAiFunctionObject } from './function-object.js';
/**
 * Representation of the 'AzureOpenAiChatCompletionTool' schema.
 */
export type AzureOpenAiChatCompletionTool = {
    /**
     * The type of the tool. Currently, only `function` is supported.
     */
    type: 'function';
    function: AzureOpenAiFunctionObject;
} & Record<string, any>;
//# sourceMappingURL=chat-completion-tool.d.ts.map