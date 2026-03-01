import type { AzureOpenAiChatCompletionTokenLogprob } from './chat-completion-token-logprob.js';
/**
 * Log probability information for the choice.
 */
export type AzureOpenAiChatCompletionChoiceLogProbs = ({
    /**
     * A list of message content tokens with log probability information.
     */
    content: AzureOpenAiChatCompletionTokenLogprob[] | null;
    /**
     * A list of message refusal tokens with log probability information.
     */
    refusal?: AzureOpenAiChatCompletionTokenLogprob[] | null;
} & Record<string, any>) | null;
//# sourceMappingURL=chat-completion-choice-log-probs.d.ts.map