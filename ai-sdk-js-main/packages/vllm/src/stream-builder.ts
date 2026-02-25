/**
 * StreamBuilder - Composable streaming utilities for vLLM responses.
 *
 * Provides a fluent API for building streaming pipelines with
 * configurable middleware and handlers.
 */

import { VllmStreamError } from './errors.js';
import { SSEParser, type SSEEvent } from './sse-parser.js';
import { transformStreamChunk, type ApiStreamChunk } from './transformers.js';
import type { VllmStreamChunk, VllmChatMessage } from './types.js';

/**
 * Configuration for stream builder.
 */
export interface StreamBuilderConfig {
  /**
   * Called for each chunk received.
   */
  onChunk?: (chunk: VllmStreamChunk) => void;

  /**
   * Called when stream completes.
   */
  onComplete?: (result: StreamResult) => void;

  /**
   * Called when an error occurs.
   */
  onError?: (error: Error) => void;

  /**
   * Called when stream starts (first chunk).
   */
  onStart?: (chunk: VllmStreamChunk) => void;

  /**
   * Called when content is received.
   */
  onContent?: (content: string) => void;

  /**
   * Called when tool calls are received.
   */
  onToolCall?: (toolCall: ToolCallDelta) => void;

  /**
   * Timeout for the stream in milliseconds.
   */
  timeout?: number;

  /**
   * Maximum chunks to process (for limiting response size).
   */
  maxChunks?: number;

  /**
   * Abort signal for cancellation.
   */
  signal?: AbortSignal;
}

/**
 * Result of a completed stream.
 */
export interface StreamResult {
  /**
   * Complete content from all chunks.
   */
  content: string;

  /**
   * Total number of chunks processed.
   */
  chunks: number;

  /**
   * Finish reason from final chunk.
   */
  finishReason: string | null;

  /**
   * Tool calls accumulated from stream.
   */
  toolCalls: ToolCallDelta[];

  /**
   * Time taken in milliseconds.
   */
  duration: number;

  /**
   * First chunk latency in milliseconds.
   */
  timeToFirstChunk: number | null;

  /**
   * Whether stream was aborted.
   */
  aborted: boolean;
}

/**
 * Partial tool call from streaming.
 */
export interface ToolCallDelta {
  index: number;
  id: string;
  type: string;
  function: {
    name: string;
    arguments: string;
  };
}

/**
 * Streaming state for accumulation.
 */
interface StreamState {
  content: string;
  chunks: number;
  finishReason: string | null;
  toolCalls: Map<number, ToolCallDelta>;
  startTime: number;
  firstChunkTime: number | null;
  started: boolean;
  aborted: boolean;
}

/**
 * Builds and executes streaming pipelines with middleware support.
 *
 * @example
 * ```typescript
 * const result = await new StreamBuilder()
 *   .onContent(text => process.stdout.write(text))
 *   .onToolCall(call => console.log('Tool:', call.function.name))
 *   .timeout(30000)
 *   .execute(client.chatStream(request));
 * ```
 */
export class StreamBuilder {
  private config: StreamBuilderConfig = {};
  private middleware: Array<(chunk: VllmStreamChunk) => VllmStreamChunk | null> = [];

  /**
   * Sets the chunk callback.
   */
  onChunk(callback: (chunk: VllmStreamChunk) => void): this {
    this.config.onChunk = callback;
    return this;
  }

  /**
   * Sets the completion callback.
   */
  onComplete(callback: (result: StreamResult) => void): this {
    this.config.onComplete = callback;
    return this;
  }

  /**
   * Sets the error callback.
   */
  onError(callback: (error: Error) => void): this {
    this.config.onError = callback;
    return this;
  }

  /**
   * Sets the start callback (called on first chunk).
   */
  onStart(callback: (chunk: VllmStreamChunk) => void): this {
    this.config.onStart = callback;
    return this;
  }

  /**
   * Sets the content callback (called with each content delta).
   */
  onContent(callback: (content: string) => void): this {
    this.config.onContent = callback;
    return this;
  }

  /**
   * Sets the tool call callback.
   */
  onToolCall(callback: (toolCall: ToolCallDelta) => void): this {
    this.config.onToolCall = callback;
    return this;
  }

  /**
   * Sets the stream timeout.
   */
  timeout(ms: number): this {
    this.config.timeout = ms;
    return this;
  }

  /**
   * Sets the maximum number of chunks to process.
   */
  maxChunks(count: number): this {
    this.config.maxChunks = count;
    return this;
  }

  /**
   * Sets an abort signal for cancellation.
   */
  signal(signal: AbortSignal): this {
    this.config.signal = signal;
    return this;
  }

  /**
   * Adds middleware to transform or filter chunks.
   */
  use(fn: (chunk: VllmStreamChunk) => VllmStreamChunk | null): this {
    this.middleware.push(fn);
    return this;
  }

  /**
   * Adds a filter middleware that drops chunks not matching predicate.
   */
  filter(predicate: (chunk: VllmStreamChunk) => boolean): this {
    return this.use((chunk) => (predicate(chunk) ? chunk : null));
  }

  /**
   * Adds a transform middleware.
   */
  map(transform: (chunk: VllmStreamChunk) => VllmStreamChunk): this {
    return this.use(transform);
  }

  /**
   * Executes the stream with configured handlers.
   * @param stream - AsyncGenerator of stream chunks
   * @returns Stream result
   */
  async execute(
    stream: AsyncGenerator<VllmStreamChunk, void, unknown>
  ): Promise<StreamResult> {
    const state: StreamState = {
      content: '',
      chunks: 0,
      finishReason: null,
      toolCalls: new Map(),
      startTime: Date.now(),
      firstChunkTime: null,
      started: false,
      aborted: false,
    };

    // Set up abort handling
    if (this.config.signal) {
      this.config.signal.addEventListener('abort', () => {
        state.aborted = true;
      });
    }

    // Set up timeout
    let timeoutId: ReturnType<typeof setTimeout> | undefined;
    if (this.config.timeout) {
      timeoutId = setTimeout(() => {
        state.aborted = true;
      }, this.config.timeout);
    }

    try {
      for await (let chunk of stream) {
        // Check for abort
        if (state.aborted) {
          break;
        }

        // Check max chunks
        if (this.config.maxChunks && state.chunks >= this.config.maxChunks) {
          state.aborted = true;
          break;
        }

        // Apply middleware
        for (const fn of this.middleware) {
          const result = fn(chunk);
          if (result === null) {
            chunk = null as unknown as VllmStreamChunk;
            break;
          }
          chunk = result;
        }

        if (chunk === null) {
          continue;
        }

        // Track first chunk
        if (!state.started) {
          state.started = true;
          state.firstChunkTime = Date.now();
          this.config.onStart?.(chunk);
        }

        // Process chunk
        state.chunks++;
        this.config.onChunk?.(chunk);

        // Extract content
        const delta = chunk.choices[0]?.delta;
        if (delta?.content) {
          state.content += delta.content;
          this.config.onContent?.(delta.content);
        }

        // Extract tool calls
        if (delta?.toolCalls) {
          for (const tc of delta.toolCalls) {
            const existing = state.toolCalls.get(tc.index ?? 0);
            if (existing) {
              // Append to existing
              if (tc.function?.arguments) {
                existing.function.arguments += tc.function.arguments;
              }
            } else {
              // New tool call
              const toolCall: ToolCallDelta = {
                index: tc.index ?? 0,
                id: tc.id ?? '',
                type: tc.type ?? 'function',
                function: {
                  name: tc.function?.name ?? '',
                  arguments: tc.function?.arguments ?? '',
                },
              };
              state.toolCalls.set(toolCall.index, toolCall);
              this.config.onToolCall?.(toolCall);
            }
          }
        }

        // Track finish reason
        if (chunk.choices[0]?.finishReason) {
          state.finishReason = chunk.choices[0].finishReason;
        }
      }

      // Build result
      const result: StreamResult = {
        content: state.content,
        chunks: state.chunks,
        finishReason: state.finishReason,
        toolCalls: Array.from(state.toolCalls.values()),
        duration: Date.now() - state.startTime,
        timeToFirstChunk: state.firstChunkTime
          ? state.firstChunkTime - state.startTime
          : null,
        aborted: state.aborted,
      };

      this.config.onComplete?.(result);
      return result;
    } catch (error) {
      const err = error instanceof Error ? error : new Error(String(error));
      this.config.onError?.(err);
      throw err;
    } finally {
      if (timeoutId) {
        clearTimeout(timeoutId);
      }
    }
  }

  /**
   * Creates a new StreamBuilder with default configuration.
   */
  static create(): StreamBuilder {
    return new StreamBuilder();
  }
}

/**
 * Converts an AsyncGenerator to a message object.
 *
 * @param stream - Stream of chunks
 * @returns Complete message object
 */
export async function streamToMessage(
  stream: AsyncGenerator<VllmStreamChunk, void, unknown>
): Promise<VllmChatMessage> {
  const result = await new StreamBuilder().execute(stream);

  const message: VllmChatMessage = {
    role: 'assistant',
    content: result.content,
  };

  if (result.toolCalls.length > 0) {
    message.toolCalls = result.toolCalls.map((tc) => ({
      id: tc.id,
      type: tc.type as 'function',
      function: tc.function,
    }));
  }

  return message;
}

/**
 * Creates a simple text accumulator for streams.
 *
 * @param onText - Called with accumulated text after each chunk
 * @returns Stream builder with text accumulation
 */
export function createTextAccumulator(
  onText?: (text: string) => void
): StreamBuilder {
  let accumulated = '';

  return new StreamBuilder()
    .onContent((content) => {
      accumulated += content;
      onText?.(accumulated);
    });
}

/**
 * Creates a token counter for streams.
 *
 * @param onCount - Called with estimated token count
 * @returns Stream builder with token counting
 */
export function createTokenCounter(
  onCount?: (tokens: number) => void
): StreamBuilder {
  let tokens = 0;

  // Rough estimation: ~4 chars per token
  return new StreamBuilder()
    .onContent((content) => {
      tokens += Math.ceil(content.length / 4);
      onCount?.(tokens);
    });
}

/**
 * Tees a stream into two independent iterators.
 *
 * @param stream - Source stream
 * @returns Tuple of two independent async generators
 */
export function teeStream(
  stream: AsyncGenerator<VllmStreamChunk, void, unknown>
): [AsyncGenerator<VllmStreamChunk, void, unknown>, AsyncGenerator<VllmStreamChunk, void, unknown>] {
  const buffer1: VllmStreamChunk[] = [];
  const buffer2: VllmStreamChunk[] = [];
  let done = false;
  let error: Error | null = null;

  // Consumer for original stream
  const consumer = (async () => {
    try {
      for await (const chunk of stream) {
        buffer1.push(chunk);
        buffer2.push(chunk);
      }
    } catch (e) {
      error = e instanceof Error ? e : new Error(String(e));
    } finally {
      done = true;
    }
  })();

  // Create generators
  async function* createBranch(buffer: VllmStreamChunk[]): AsyncGenerator<VllmStreamChunk, void, unknown> {
    let index = 0;
    while (true) {
      if (index < buffer.length) {
        yield buffer[index++];
      } else if (done) {
        if (error) throw error;
        return;
      } else {
        // Wait for more data
        await new Promise((resolve) => setTimeout(resolve, 1));
      }
    }
  }

  return [createBranch(buffer1), createBranch(buffer2)];
}