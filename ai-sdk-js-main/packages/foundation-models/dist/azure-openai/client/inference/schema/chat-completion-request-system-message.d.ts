import type { AzureOpenAiChatCompletionRequestSystemMessageContentPart } from './chat-completion-request-system-message-content-part.js';
/**
 * Representation of the 'AzureOpenAiChatCompletionRequestSystemMessage' schema.
 */
export type AzureOpenAiChatCompletionRequestSystemMessage = {
    /**
     * The contents of the system message.
     */
    content: string | AzureOpenAiChatCompletionRequestSystemMessageContentPart[];
    /**
     * The role of the messages author, in this case `system`.
     */
    role: 'system';
    /**
     * An optional name for the participant. Provides the model information to differentiate between participants of the same role.
     */
    name?: string;
} & Record<string, any>;
//# sourceMappingURL=chat-completion-request-system-message.d.ts.map