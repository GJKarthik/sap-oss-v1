/**
 * Azure OpenAI chat completion stream chunk response.
 */
export class AzureOpenAiChatCompletionStreamChunkResponse {
    _data;
    constructor(_data) {
        this._data = _data;
        this._data = _data;
    }
    /**
     * Usage of tokens in the chunk response.
     * @returns Token usage.
     */
    getTokenUsage() {
        return this._data.usage;
    }
    /**
     * Reason for stopping the completion stream chunk.
     * @param choiceIndex - The index of the choice to parse.
     * @returns The finish reason.
     */
    getFinishReason(choiceIndex = 0) {
        return this.findChoiceByIndex(choiceIndex)?.finish_reason;
    }
    /**
     * Parses the chunk response and returns the delta content.
     * @param choiceIndex - The index of the choice to parse.
     * @returns The message delta content.
     */
    getDeltaContent(choiceIndex = 0) {
        return this.findChoiceByIndex(choiceIndex)?.delta.content;
    }
    /**
     * Gets the delta tool calls for a specific choice index.
     * @param choiceIndex - The index of the choice to parse.
     * @returns The delta tool calls for the specified choice index.
     */
    getDeltaToolCalls(choiceIndex = 0) {
        return this.findChoiceByIndex(choiceIndex)?.delta.tool_calls;
    }
    /**
     * Parses the chunk response and returns the choice by index.
     * @param index - The index of the choice to find.
     * @returns An {@link LLMChoiceStreaming} object associated withe index.
     */
    findChoiceByIndex(index) {
        return this.getChoices()?.find(c => c.index === index);
    }
    getChoices() {
        return this._data.choices;
    }
}
//# sourceMappingURL=azure-openai-chat-completion-stream-chunk-response.js.map