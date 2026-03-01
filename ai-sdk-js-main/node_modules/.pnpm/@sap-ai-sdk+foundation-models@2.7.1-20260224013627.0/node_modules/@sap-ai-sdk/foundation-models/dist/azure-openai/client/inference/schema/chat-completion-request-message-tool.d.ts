import type { AzureOpenAiChatCompletionRequestMessage } from './chat-completion-request-message.js';
/**
 * Representation of the 'AzureOpenAiChatCompletionRequestMessageTool' schema.
 */
export type AzureOpenAiChatCompletionRequestMessageTool = AzureOpenAiChatCompletionRequestMessage & {
    /**
     * Tool call that this message is responding to.
     */
    tool_call_id: string;
    /**
     * The contents of the message.
     */
    content: string | null;
} & Record<string, any>;
//# sourceMappingURL=chat-completion-request-message-tool.d.ts.map