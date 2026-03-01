// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Server-Sent Events (SSE) parser for vLLM streaming responses.
 *
 * Handles parsing of SSE stream data according to the SSE specification:
 * https://html.spec.whatwg.org/multipage/server-sent-events.html
 */

import { VllmStreamError } from './errors.js';
import { transformStreamChunk, type ApiStreamChunk } from './transformers.js';
import type { VllmStreamChunk } from './types.js';

/**
 * SSE event structure.
 */
export interface SSEEvent {
  /**
   * Event type (from "event:" field).
   */
  event?: string;

  /**
   * Event data (from "data:" field).
   */
  data: string;

  /**
   * Event ID (from "id:" field).
   */
  id?: string;

  /**
   * Retry timeout in milliseconds (from "retry:" field).
   */
  retry?: number;
}

/**
 * Parser state for handling multi-line data.
 */
interface ParserState {
  event: string | undefined;
  data: string[];
  id: string | undefined;
  retry: number | undefined;
}

/**
 * Parses Server-Sent Events from a stream.
 */
export class SSEParser {
  private buffer: string = '';
  private state: ParserState = {
    event: undefined,
    data: [],
    id: undefined,
    retry: undefined,
  };
  private lastEventId: string | undefined;

  /**
   * Creates a new SSE parser.
   * @param onEvent - Callback for parsed events
   * @param onError - Callback for parse errors
   */
  constructor(
    private readonly onEvent?: (event: SSEEvent) => void,
    private readonly onError?: (error: Error) => void
  ) {}

  /**
   * Feeds data to the parser.
   * @param chunk - Raw string data from stream
   * @returns Array of parsed events
   */
  feed(chunk: string): SSEEvent[] {
    this.buffer += chunk;
    const events: SSEEvent[] = [];

    // Split by line endings (handle \r\n, \n, \r)
    const lines = this.buffer.split(/\r\n|\n|\r/);

    // Keep the last incomplete line in buffer
    this.buffer = lines.pop() ?? '';

    for (const line of lines) {
      const event = this.processLine(line);
      if (event) {
        events.push(event);
        this.onEvent?.(event);
      }
    }

    return events;
  }

  /**
   * Processes a single line of SSE data.
   * @param line - Single line from stream
   * @returns Parsed event if complete, undefined otherwise
   */
  private processLine(line: string): SSEEvent | undefined {
    // Dispatch event on empty line
    if (line === '') {
      return this.dispatchEvent();
    }

    // Ignore comment lines (start with :)
    if (line.startsWith(':')) {
      return undefined;
    }

    // Parse field: value
    const colonIndex = line.indexOf(':');
    let field: string;
    let value: string;

    if (colonIndex === -1) {
      // Line is just field name
      field = line;
      value = '';
    } else {
      field = line.substring(0, colonIndex);
      value = line.substring(colonIndex + 1);

      // Remove leading space from value if present
      if (value.startsWith(' ')) {
        value = value.substring(1);
      }
    }

    // Process field
    switch (field) {
      case 'event':
        this.state.event = value;
        break;
      case 'data':
        this.state.data.push(value);
        break;
      case 'id':
        // Empty id resets, non-empty sets
        if (value === '') {
          this.state.id = undefined;
        } else {
          this.state.id = value;
        }
        break;
      case 'retry':
        const retry = parseInt(value, 10);
        if (!isNaN(retry) && retry >= 0) {
          this.state.retry = retry;
        }
        break;
      // Ignore unknown fields
    }

    return undefined;
  }

  /**
   * Dispatches accumulated event data.
   * @returns Parsed event or undefined if no data
   */
  private dispatchEvent(): SSEEvent | undefined {
    // Only dispatch if we have data
    if (this.state.data.length === 0) {
      this.resetState();
      return undefined;
    }

    // Build event
    const event: SSEEvent = {
      data: this.state.data.join('\n'),
    };

    if (this.state.event) {
      event.event = this.state.event;
    }

    if (this.state.id !== undefined) {
      event.id = this.state.id;
      this.lastEventId = this.state.id;
    } else if (this.lastEventId) {
      event.id = this.lastEventId;
    }

    if (this.state.retry !== undefined) {
      event.retry = this.state.retry;
    }

    // Reset state for next event
    this.resetState();

    return event;
  }

  /**
   * Resets parser state for next event.
   */
  private resetState(): void {
    this.state = {
      event: undefined,
      data: [],
      id: undefined,
      retry: undefined,
    };
  }

  /**
   * Flushes any remaining data in buffer.
   * @returns Final event if any
   */
  flush(): SSEEvent | undefined {
    // Process remaining buffer as complete line
    if (this.buffer) {
      this.processLine(this.buffer);
      this.buffer = '';
    }

    // Dispatch any pending event
    return this.dispatchEvent();
  }

  /**
   * Gets the last event ID seen.
   */
  getLastEventId(): string | undefined {
    return this.lastEventId;
  }

  /**
   * Resets the parser to initial state.
   */
  reset(): void {
    this.buffer = '';
    this.lastEventId = undefined;
    this.resetState();
  }
}

/**
 * Parses SSE stream data and yields vLLM chat completion chunks.
 *
 * @param stream - ReadableStream from HTTP response
 * @yields VllmStreamChunk objects
 *
 * @example
 * ```typescript
 * const stream = await fetch(url, { ... });
 * for await (const chunk of parseSSEStream(stream.body)) {
 *   console.log(chunk.choices[0].delta.content);
 * }
 * ```
 */
export async function* parseSSEStream(
  stream: ReadableStream<Uint8Array>
): AsyncGenerator<VllmStreamChunk, void, unknown> {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  const parser = new SSEParser();

  try {
    while (true) {
      const { done, value } = await reader.read();

      if (done) {
        // Flush any remaining data
        const finalEvent = parser.flush();
        if (finalEvent && finalEvent.data !== '[DONE]') {
          try {
            const chunk = JSON.parse(finalEvent.data) as ApiStreamChunk;
            yield transformStreamChunk(chunk);
          } catch {
            // Ignore parse errors on flush
          }
        }
        break;
      }

      // Decode and feed to parser
      const text = decoder.decode(value, { stream: true });
      const events = parser.feed(text);

      // Process each parsed event
      for (const event of events) {
        // Skip [DONE] marker
        if (event.data === '[DONE]') {
          return;
        }

        try {
          const chunk = JSON.parse(event.data) as ApiStreamChunk;
          yield transformStreamChunk(chunk);
        } catch (error) {
          // Skip malformed chunks
          continue;
        }
      }
    }
  } finally {
    reader.releaseLock();
  }
}

/**
 * Creates a transform stream that parses SSE events.
 *
 * @returns TransformStream that converts raw bytes to SSE events
 *
 * @example
 * ```typescript
 * const sseStream = response.body
 *   .pipeThrough(createSSETransformStream())
 *   .getReader();
 * ```
 */
export function createSSETransformStream(): TransformStream<Uint8Array, SSEEvent> {
  const decoder = new TextDecoder();
  const parser = new SSEParser();

  return new TransformStream({
    transform(chunk, controller) {
      const text = decoder.decode(chunk, { stream: true });
      const events = parser.feed(text);
      for (const event of events) {
        controller.enqueue(event);
      }
    },
    flush(controller) {
      const finalEvent = parser.flush();
      if (finalEvent) {
        controller.enqueue(finalEvent);
      }
    },
  });
}

/**
 * Creates a transform stream that converts SSE events to VllmStreamChunks.
 *
 * @returns TransformStream that converts SSE events to VllmStreamChunks
 */
export function createChunkTransformStream(): TransformStream<SSEEvent, VllmStreamChunk> {
  return new TransformStream({
    transform(event, controller) {
      // Skip [DONE] marker
      if (event.data === '[DONE]') {
        return;
      }

      try {
        const apiChunk = JSON.parse(event.data) as ApiStreamChunk;
        const chunk = transformStreamChunk(apiChunk);
        controller.enqueue(chunk);
      } catch {
        // Skip malformed chunks
      }
    },
  });
}

/**
 * Collects stream chunks into a complete response.
 *
 * @param stream - AsyncGenerator of stream chunks
 * @returns Complete content string and total chunks processed
 *
 * @example
 * ```typescript
 * const { content, chunks } = await collectStreamContent(client.chatStream(request));
 * console.log(`Received ${chunks} chunks: ${content}`);
 * ```
 */
export async function collectStreamContent(
  stream: AsyncGenerator<VllmStreamChunk, void, unknown>
): Promise<{ content: string; chunks: number; finishReason: string | null }> {
  let content = '';
  let chunks = 0;
  let finishReason: string | null = null;

  for await (const chunk of stream) {
    chunks++;

    // Accumulate content
    const delta = chunk.choices[0]?.delta;
    if (delta?.content) {
      content += delta.content;
    }

    // Track finish reason
    if (chunk.choices[0]?.finishReason) {
      finishReason = chunk.choices[0].finishReason;
    }
  }

  return { content, chunks, finishReason };
}

/**
 * Creates a callback-based stream consumer.
 *
 * @param stream - AsyncGenerator of stream chunks
 * @param onChunk - Callback for each chunk
 * @param onComplete - Callback when stream completes
 * @param onError - Callback on error
 *
 * @example
 * ```typescript
 * consumeStream(
 *   client.chatStream(request),
 *   (chunk) => process.stdout.write(chunk.choices[0].delta.content ?? ''),
 *   (result) => console.log('\nDone:', result.finishReason),
 *   (error) => console.error('Error:', error)
 * );
 * ```
 */
export async function consumeStream(
  stream: AsyncGenerator<VllmStreamChunk, void, unknown>,
  onChunk: (chunk: VllmStreamChunk) => void,
  onComplete?: (result: { content: string; chunks: number; finishReason: string | null }) => void,
  onError?: (error: Error) => void
): Promise<void> {
  let content = '';
  let chunks = 0;
  let finishReason: string | null = null;

  try {
    for await (const chunk of stream) {
      chunks++;
      onChunk(chunk);

      const delta = chunk.choices[0]?.delta;
      if (delta?.content) {
        content += delta.content;
      }

      if (chunk.choices[0]?.finishReason) {
        finishReason = chunk.choices[0].finishReason;
      }
    }

    onComplete?.({ content, chunks, finishReason });
  } catch (error) {
    onError?.(error instanceof Error ? error : new Error(String(error)));
  }
}