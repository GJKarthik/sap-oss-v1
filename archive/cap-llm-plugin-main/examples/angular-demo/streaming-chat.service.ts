// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * StreamingChatService — Angular service for streaming chat completion via SSE.
 *
 * Uses the native `fetch` API with `ReadableStream` to consume the
 * `streamChatCompletion` CAP action as a Server-Sent Events stream.
 * Returns an `Observable<string>` that emits one delta string per token.
 *
 * Usage:
 *
 *   constructor(private streaming: StreamingChatService) {}
 *
 *   this.streaming.streamChat({
 *     clientConfig: { promptTemplating: { model: { name: "gpt-4o" } } },
 *     chatCompletionConfig: { messages: [{ role: "user", content: "Hello" }] },
 *   }).subscribe({
 *     next: delta  => this.tokens += delta,
 *     error: err   => console.error(err),
 *     complete: () => console.log("done"),
 *   });
 *
 * Cancel mid-stream by unsubscribing:
 *
 *   const sub = this.streaming.streamChat(...).subscribe(...);
 *   sub.unsubscribe(); // sends AbortSignal → server stops generating
 *
 * NOTE: This is a reference example, not a runnable app.
 * Copy into your Angular project and adjust imports/URL as needed.
 *
 * Requires: Angular 15+ (for the inject() / standalone pattern).
 * Compatible with NgModule-based apps — just inject via constructor.
 */

import { Injectable } from "@angular/core";
import { Observable } from "rxjs";

// ════════════════════════════════════════════════════════════════════
// Types
// ════════════════════════════════════════════════════════════════════

/** Request parameters for streamChatCompletion (mirrors the CDS action). */
export interface StreamChatRequest {
  /** JSON-serializable OrchestrationModuleConfig object. */
  clientConfig: Record<string, unknown>;
  /** JSON-serializable ChatCompletionRequest object. */
  chatCompletionConfig: Record<string, unknown>;
  /** If true, abort the stream when a content filter violation is detected. Default true. */
  abortOnFilterViolation?: boolean;
}

/** Parsed SSE delta frame. */
export interface StreamDeltaFrame {
  delta: string;
  index: number;
}

/** Parsed SSE done frame (last data frame before [DONE] sentinel). */
export interface StreamDoneFrame {
  finishReason: string | undefined;
  totalTokens: number | undefined;
}

/** Parsed SSE error frame. */
export interface StreamErrorFrame {
  code: string;
  message: string;
}

/** Emitted by streamChat() after all tokens have arrived. */
export interface StreamSummary {
  finishReason: string | undefined;
  totalTokens: number | undefined;
  fullContent: string;
}

// ════════════════════════════════════════════════════════════════════
// Service
// ════════════════════════════════════════════════════════════════════

@Injectable({ providedIn: "root" })
export class StreamingChatService {
  /**
   * Base URL for the CAP service. Override in a subclass or via provider
   * if your app mounts the service at a different path.
   */
  protected readonly baseUrl = "/odata/v4/CAPLLMPluginService";

  // ── Public API ─────────────────────────────────────────────────────

  /**
   * Stream chat completion tokens as they are generated.
   *
   * @param request - Client config + chat completion config.
   * @returns Observable<string> emitting one delta token per `next` call.
   *   Completes when the server sends `[DONE]`.
   *   Errors with a `StreamChatError` if the server sends an error frame
   *   or if the `fetch` itself fails.
   */
  streamChat(request: StreamChatRequest): Observable<string> {
    return new Observable<string>((subscriber) => {
      const controller = new AbortController();

      const body = JSON.stringify({
        clientConfig: JSON.stringify(request.clientConfig),
        chatCompletionConfig: JSON.stringify(request.chatCompletionConfig),
        abortOnFilterViolation: request.abortOnFilterViolation ?? true,
      });

      fetch(`${this.baseUrl}/streamChatCompletion`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "text/event-stream",
        },
        body,
        signal: controller.signal,
      })
        .then((res) => {
          if (!res.ok) {
            throw new StreamChatError(
              `HTTP ${res.status} ${res.statusText}`,
              "HTTP_ERROR",
            );
          }
          if (!res.body) {
            throw new StreamChatError(
              "Response body is null — SSE not supported by this environment.",
              "NO_RESPONSE_BODY",
            );
          }
          return this._consumeStream(res.body, subscriber);
        })
        .catch((err: unknown) => {
          if (isAbortError(err)) {
            // Normal unsubscribe — complete silently
            subscriber.complete();
          } else {
            subscriber.error(
              err instanceof StreamChatError
                ? err
                : new StreamChatError(
                    (err as Error).message ?? "Unknown fetch error",
                    "FETCH_ERROR",
                  ),
            );
          }
        });

      // Teardown: abort the fetch when the subscriber unsubscribes
      return () => { controller.abort(); };
    });
  }

  /**
   * Stream chat completion and accumulate the full response.
   *
   * Convenience wrapper over `streamChat()` that collects all deltas and
   * emits a single `StreamSummary` on completion.
   *
   * @param request - Client config + chat completion config.
   * @returns Observable<StreamSummary> emitting exactly one item.
   */
  streamChatFull(request: StreamChatRequest): Observable<StreamSummary> {
    return new Observable<StreamSummary>((subscriber) => {
      let fullContent = "";

      const inner = this.streamChat(request).subscribe({
        next: (delta) => { fullContent += delta; },
        error: (err) => subscriber.error(err),
        complete: () => {
          subscriber.next({ finishReason: undefined, totalTokens: undefined, fullContent });
          subscriber.complete();
        },
      });

      return () => inner.unsubscribe();
    });
  }

  // ── Stream consumption internals ───────────────────────────────────

  /**
   * Reads a `ReadableStream<Uint8Array>` and dispatches SSE frames to the
   * subscriber. Handles multi-line SSE frames and partial chunk boundaries.
   */
  private async _consumeStream(
    body: ReadableStream<Uint8Array>,
    subscriber: { next(v: string): void; error(e: unknown): void; complete(): void },
  ): Promise<void> {
    const reader = body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });

        // SSE frames are separated by double newlines
        const frames = buffer.split("\n\n");
        // Last element may be incomplete — keep it in the buffer
        buffer = frames.pop()!;

        for (const frame of frames) {
          this._dispatchFrame(frame.trim(), subscriber);
        }
      }

      // Flush any remaining buffer content
      if (buffer.trim()) {
        this._dispatchFrame(buffer.trim(), subscriber);
      }
    } catch (err: unknown) {
      if (!isAbortError(err)) {
        subscriber.error(
          new StreamChatError((err as Error).message ?? "Stream read error", "STREAM_READ_ERROR"),
        );
      }
    } finally {
      reader.releaseLock();
    }
  }

  /**
   * Parse a single SSE frame string and dispatch it to the subscriber.
   *
   * Handles:
   *   - `data: {"delta":"...","index":0}` → next(delta)
   *   - `data: {"finishReason":"...","totalTokens":...}` → (ignored, summary carried by [DONE])
   *   - `data: [DONE]` → complete()
   *   - `event: error\ndata: {"code":"...","message":"..."}` → error()
   */
  private _dispatchFrame(
    frame: string,
    subscriber: { next(v: string): void; error(e: unknown): void; complete(): void },
  ): void {
    if (!frame) return;

    // Error frame: starts with "event: error"
    if (frame.startsWith("event: error")) {
      const dataLine = frame.split("\n").find((l) => l.startsWith("data:"));
      if (dataLine) {
        try {
          const parsed = JSON.parse(dataLine.slice(5).trim()) as StreamErrorFrame;
          subscriber.error(new StreamChatError(parsed.message, parsed.code));
        } catch {
          subscriber.error(new StreamChatError("Unparseable error frame", "PARSE_ERROR"));
        }
      }
      return;
    }

    // Data frame
    const lines = frame.split("\n");
    for (const line of lines) {
      if (!line.startsWith("data:")) continue;
      const payload = line.slice(5).trim();

      // Sentinel
      if (payload === "[DONE]") {
        subscriber.complete();
        return;
      }

      try {
        const parsed = JSON.parse(payload) as StreamDeltaFrame | StreamDoneFrame;

        // Delta frame
        if ("delta" in parsed && parsed.delta) {
          subscriber.next(parsed.delta);
        }
        // Done metadata frame — ignored here; component uses complete() to react
      } catch {
        // Malformed JSON in a data frame — skip silently
      }
    }
  }
}

// ════════════════════════════════════════════════════════════════════
// Error class
// ════════════════════════════════════════════════════════════════════

/** Error thrown by StreamingChatService when streaming fails. */
export class StreamChatError extends Error {
  constructor(
    message: string,
    public readonly code: string,
  ) {
    super(message);
    this.name = "StreamChatError";
  }
}

// ════════════════════════════════════════════════════════════════════
// Helpers
// ════════════════════════════════════════════════════════════════════

function isAbortError(err: unknown): boolean {
  return (
    err instanceof Error &&
    (err.name === "AbortError" || (err as { code?: string }).code === "ABORT_ERR")
  );
}
