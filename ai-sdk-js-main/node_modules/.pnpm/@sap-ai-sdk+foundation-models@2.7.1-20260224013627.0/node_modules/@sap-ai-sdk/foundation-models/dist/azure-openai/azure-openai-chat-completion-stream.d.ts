import { SseStream } from '@sap-ai-sdk/core';
import { AzureOpenAiChatCompletionStreamChunkResponse } from './azure-openai-chat-completion-stream-chunk-response.js';
import type { AzureOpenAiCreateChatCompletionStreamResponse } from './client/inference/schema/index.js';
import type { HttpResponse } from '@sap-cloud-sdk/http-client';
import type { AzureOpenAiChatCompletionStreamResponse } from './azure-openai-chat-completion-stream-response.js';
/**
 * Chat completion stream containing post-processing functions.
 */
export declare class AzureOpenAiChatCompletionStream<Item> extends SseStream<Item> {
    iterator: () => AsyncIterator<Item>;
    /**
     * Create a chat completion stream based on the http response.
     * @param response - Http response.
     * @returns Chat completion stream.
     * @internal
     */
    static _create(response: HttpResponse, controller: AbortController): AzureOpenAiChatCompletionStream<AzureOpenAiCreateChatCompletionStreamResponse>;
    /**
     * Wrap raw chunk data with chunk response class to provide helper functions.
     * @param stream - Chat completion stream.
     * @internal
     */
    static _processChunk(stream: AzureOpenAiChatCompletionStream<AzureOpenAiCreateChatCompletionStreamResponse>): AsyncGenerator<AzureOpenAiChatCompletionStreamChunkResponse>;
    /**
     * @internal
     */
    static _processToolCalls(stream: AzureOpenAiChatCompletionStream<AzureOpenAiChatCompletionStreamChunkResponse>, response?: AzureOpenAiChatCompletionStreamResponse<AzureOpenAiChatCompletionStreamChunkResponse>): AsyncGenerator<AzureOpenAiChatCompletionStreamChunkResponse>;
    /**
     * @internal
     */
    static _processFinishReason(stream: AzureOpenAiChatCompletionStream<AzureOpenAiChatCompletionStreamChunkResponse>, response?: AzureOpenAiChatCompletionStreamResponse<AzureOpenAiChatCompletionStreamChunkResponse>): AsyncGenerator<AzureOpenAiChatCompletionStreamChunkResponse>;
    /**
     * @internal
     */
    static _processTokenUsage(stream: AzureOpenAiChatCompletionStream<AzureOpenAiChatCompletionStreamChunkResponse>, response?: AzureOpenAiChatCompletionStreamResponse<AzureOpenAiChatCompletionStreamChunkResponse>): AsyncGenerator<AzureOpenAiChatCompletionStreamChunkResponse>;
    /**
     * Transform a stream of chunks into a stream of content strings.
     * @param stream - Chat completion stream.
     * @param choiceIndex - The index of the choice to parse.
     * @internal
     */
    static _processContentStream(stream: AzureOpenAiChatCompletionStream<AzureOpenAiChatCompletionStreamChunkResponse>, choiceIndex?: number): AsyncGenerator<string>;
    constructor(iterator: () => AsyncIterator<Item>, controller: AbortController);
    /**
     * Pipe the stream through a processing function.
     * @param processFn - The function to process the input stream.
     * @param response - The `AzureOpenAiChatCompletionStreamResponse` object for process function to store finish reason, token usage, etc.
     * @returns The output stream containing processed items.
     * @internal
     */
    _pipe<TReturn>(processFn: (stream: AzureOpenAiChatCompletionStream<Item>, response?: AzureOpenAiChatCompletionStreamResponse<any>) => AsyncIterator<TReturn>, response?: AzureOpenAiChatCompletionStreamResponse<any>): AzureOpenAiChatCompletionStream<TReturn>;
    toContentStream(this: AzureOpenAiChatCompletionStream<AzureOpenAiChatCompletionStreamChunkResponse>, choiceIndex?: number): AzureOpenAiChatCompletionStream<string>;
}
//# sourceMappingURL=azure-openai-chat-completion-stream.d.ts.map