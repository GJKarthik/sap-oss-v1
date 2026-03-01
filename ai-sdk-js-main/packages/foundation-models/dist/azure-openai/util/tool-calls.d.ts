import type { AzureOpenAiChatCompletionMessageToolCall, AzureOpenAiChatCompletionMessageToolCallChunk } from '../client/inference/schema/index.js';
/**
 * @internal
 */
export type ToolCallAccumulator = {
    id?: string;
    type: 'function';
    function: {
        name?: string;
        arguments?: string;
    } & Record<string, any>;
} & Record<string, any>;
/**
 * @internal
 * Check if the accumulator is a AzureOpenAiChatCompletionMessageToolCall.
 */
export declare function isMessageToolCall(acc: ToolCallAccumulator): acc is AzureOpenAiChatCompletionMessageToolCall;
/**
 * Merge a stream of AzureOpenAiChatCompletionMessageToolCallChunk into a single AzureOpenAiChatCompletionMessageToolCall.
 * @throws If the final object is missing required fields.
 * @internal
 */
export declare function mergeToolCallChunk(chunk: AzureOpenAiChatCompletionMessageToolCallChunk, acc?: ToolCallAccumulator): ToolCallAccumulator;
//# sourceMappingURL=tool-calls.d.ts.map