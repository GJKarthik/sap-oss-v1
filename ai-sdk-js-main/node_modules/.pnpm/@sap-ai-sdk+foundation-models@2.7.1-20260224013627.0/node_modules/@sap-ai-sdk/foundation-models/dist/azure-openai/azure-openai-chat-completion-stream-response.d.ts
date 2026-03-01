import { type ToolCallAccumulator } from './util/index.js';
import type { AzureOpenAiChatCompletionMessageToolCalls, AzureOpenAiCompletionUsage, AzureOpenAiCreateChatCompletionStreamResponse } from './client/inference/schema/index.js';
import type { AzureOpenAiChatCompletionStream } from './azure-openai-chat-completion-stream.js';
/**
 * Azure OpenAI chat completion stream response.
 */
export declare class AzureOpenAiChatCompletionStreamResponse<T> {
    private _usage;
    /**
     * Finish reasons for all choices.
     */
    private _finishReasons;
    private _toolCallsAccumulators;
    private _toolCalls;
    private _stream;
    getTokenUsage(): AzureOpenAiCompletionUsage | undefined;
    /**
     * @internal
     */
    _setTokenUsage(usage: AzureOpenAiCompletionUsage): void;
    getFinishReason(choiceIndex?: number): AzureOpenAiCreateChatCompletionStreamResponse['choices'][0]['finish_reason'] | undefined;
    /**
     * @internal
     */
    _getFinishReasons(): Map<number, AzureOpenAiCreateChatCompletionStreamResponse['choices'][0]['finish_reason']>;
    /**
     * @internal
     */
    _setFinishReasons(finishReasons: Map<number, AzureOpenAiCreateChatCompletionStreamResponse['choices'][0]['finish_reason']>): void;
    /**
     * Gets the tool calls for a specific choice index.
     * @param choiceIndex - The index of the choice to get the tool calls for.
     * @returns The tool calls for the specified choice index.
     */
    getToolCalls(choiceIndex?: number): AzureOpenAiChatCompletionMessageToolCalls | undefined;
    /**
     * @internal
     */
    _setToolCalls(choiceIndex: number, toolCalls: AzureOpenAiChatCompletionMessageToolCalls): void;
    /**
     * @internal
     */
    _getToolCallsAccumulators(): Map<number, Map<number, ToolCallAccumulator>>;
    get stream(): AzureOpenAiChatCompletionStream<T>;
    /**
     * @internal
     */
    set stream(stream: AzureOpenAiChatCompletionStream<T>);
}
//# sourceMappingURL=azure-openai-chat-completion-stream-response.d.ts.map