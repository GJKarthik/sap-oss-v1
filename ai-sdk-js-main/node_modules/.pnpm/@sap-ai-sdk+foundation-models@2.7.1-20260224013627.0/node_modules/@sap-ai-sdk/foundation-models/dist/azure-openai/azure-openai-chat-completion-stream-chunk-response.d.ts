import type { AzureOpenAiChatCompletionMessageToolCallChunk, AzureOpenAiCompletionUsage, AzureOpenAiCreateChatCompletionStreamResponse } from './client/inference/schema/index.js';
/**
 * Azure OpenAI chat completion stream chunk response.
 */
export declare class AzureOpenAiChatCompletionStreamChunkResponse {
    readonly _data: AzureOpenAiCreateChatCompletionStreamResponse;
    constructor(_data: AzureOpenAiCreateChatCompletionStreamResponse);
    /**
     * Usage of tokens in the chunk response.
     * @returns Token usage.
     */
    getTokenUsage(): AzureOpenAiCompletionUsage | null;
    /**
     * Reason for stopping the completion stream chunk.
     * @param choiceIndex - The index of the choice to parse.
     * @returns The finish reason.
     */
    getFinishReason(choiceIndex?: number): AzureOpenAiCreateChatCompletionStreamResponse['choices'][0]['finish_reason'] | undefined;
    /**
     * Parses the chunk response and returns the delta content.
     * @param choiceIndex - The index of the choice to parse.
     * @returns The message delta content.
     */
    getDeltaContent(choiceIndex?: number): string | undefined | null;
    /**
     * Gets the delta tool calls for a specific choice index.
     * @param choiceIndex - The index of the choice to parse.
     * @returns The delta tool calls for the specified choice index.
     */
    getDeltaToolCalls(choiceIndex?: number): AzureOpenAiChatCompletionMessageToolCallChunk[] | undefined;
    /**
     * Parses the chunk response and returns the choice by index.
     * @param index - The index of the choice to find.
     * @returns An {@link LLMChoiceStreaming} object associated withe index.
     */
    findChoiceByIndex(index: number): AzureOpenAiCreateChatCompletionStreamResponse['choices'][0] | undefined;
    private getChoices;
}
//# sourceMappingURL=azure-openai-chat-completion-stream-chunk-response.d.ts.map