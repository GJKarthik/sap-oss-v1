import type { AzureOpenAiChatCompletionRequestMessage } from './chat-completion-request-message.js';
/**
 * Representation of the 'AzureOpenAiChatCompletionRequestMessageFunction' schema.
 */
export type AzureOpenAiChatCompletionRequestMessageFunction = AzureOpenAiChatCompletionRequestMessage & {
    /**
     * The role of the messages author, in this case `function`.
     */
    role?: 'function';
    /**
     * The contents of the message.
     */
    name?: string;
    /**
     * The contents of the message.
     */
    content: string | null;
} & Record<string, any>;
//# sourceMappingURL=chat-completion-request-message-function.d.ts.map