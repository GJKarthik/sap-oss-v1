/**
 * Azure OpenAI chat completion stream response.
 */
export class AzureOpenAiChatCompletionStreamResponse {
    _usage;
    /**
     * Finish reasons for all choices.
     */
    _finishReasons = new Map();
    _toolCallsAccumulators = new Map();
    _toolCalls = new Map();
    _stream;
    getTokenUsage() {
        return this._usage;
    }
    /**
     * @internal
     */
    _setTokenUsage(usage) {
        this._usage = usage;
    }
    getFinishReason(choiceIndex = 0) {
        return this._finishReasons.get(choiceIndex);
    }
    /**
     * @internal
     */
    _getFinishReasons() {
        return this._finishReasons;
    }
    /**
     * @internal
     */
    _setFinishReasons(finishReasons) {
        this._finishReasons = finishReasons;
    }
    /**
     * Gets the tool calls for a specific choice index.
     * @param choiceIndex - The index of the choice to get the tool calls for.
     * @returns The tool calls for the specified choice index.
     */
    getToolCalls(choiceIndex = 0) {
        return this._toolCalls.get(choiceIndex);
    }
    /**
     * @internal
     */
    _setToolCalls(choiceIndex, toolCalls) {
        this._toolCalls.set(choiceIndex, toolCalls);
    }
    /**
     * @internal
     */
    _getToolCallsAccumulators() {
        return this._toolCallsAccumulators;
    }
    get stream() {
        if (!this._stream) {
            throw new Error('Response stream is undefined.');
        }
        return this._stream;
    }
    /**
     * @internal
     */
    set stream(stream) {
        this._stream = stream;
    }
}
//# sourceMappingURL=azure-openai-chat-completion-stream-response.js.map