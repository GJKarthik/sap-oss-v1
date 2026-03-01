// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * StreamingChatComponent — Angular component for progressive token rendering.
 *
 * Demonstrates integrating StreamingChatService to render chat responses
 * token-by-token as they arrive from the CAP streamChatCompletion SSE endpoint.
 *
 * Features:
 *  - Progressive rendering: tokens appended as they stream in
 *  - Cancel button: unsubscribes → AbortController aborts the server stream
 *  - Error display with user-friendly messages
 *  - Token counter and finish reason display
 *  - OTel tracing via TracingService (graceful no-op when OTel not installed)
 *  - Conversation history preserved across turns
 *  - Auto-scroll to latest token (via ViewChild on the messages container)
 *
 * Usage in NgModule app:
 *   declarations: [StreamingChatComponent]
 *   providers: [StreamingChatService]
 *
 * Usage in standalone Angular 17+:
 *   imports: [StreamingChatComponent]
 *
 * NOTE: This is a reference example, not a runnable app.
 * Copy into your Angular project and adjust imports/paths as needed.
 */

import {
  Component,
  OnDestroy,
  ChangeDetectionStrategy,
  ChangeDetectorRef,
  ViewChild,
  ElementRef,
} from "@angular/core";
import { Subscription } from "rxjs";
import {
  StreamingChatService,
  StreamChatRequest,
  StreamChatError,
} from "./streaming-chat.service";
import { TracingService } from "./tracing.service";

// ════════════════════════════════════════════════════════════════════
// Types
// ════════════════════════════════════════════════════════════════════

export interface ChatTurn {
  role: "user" | "assistant";
  content: string;
  /** True while the assistant turn is still streaming. */
  streaming?: boolean;
  /** Tokens received so far (only set on assistant turns). */
  tokenCount?: number;
  /** Finish reason once streaming ends (e.g. "stop", "length"). */
  finishReason?: string;
}

// ════════════════════════════════════════════════════════════════════
// Component
// ════════════════════════════════════════════════════════════════════

@Component({
  selector: "app-streaming-chat",
  templateUrl: "./streaming-chat.component.html",
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class StreamingChatComponent implements OnDestroy {
  // ── State ──────────────────────────────────────────────────────────
  turns: ChatTurn[] = [];
  userInput = "";
  error: string | null = null;

  /** True when a streaming response is in flight. */
  get isStreaming(): boolean { return !!this._streamSub && !this._streamSub.closed; }

  // ── Private ────────────────────────────────────────────────────────
  private _streamSub: Subscription | null = null;

  @ViewChild("messagesEnd") private _messagesEnd!: ElementRef<HTMLDivElement>;

  // ── Config (adjust to match your SAP AI Core deployment) ──────────
  private readonly _clientConfig = {
    promptTemplating: {
      model: { name: "gpt-4o" },
    },
  };

  constructor(
    private readonly _streaming: StreamingChatService,
    private readonly _tracing: TracingService,
    private readonly _cd: ChangeDetectorRef,
  ) {}

  ngOnDestroy(): void {
    this._streamSub?.unsubscribe();
  }

  // ── Public actions ─────────────────────────────────────────────────

  /** Submit the current user input and start streaming. */
  send(): void {
    const text = this.userInput.trim();
    if (!text || this.isStreaming) return;

    this.error = null;
    this.userInput = "";

    // Add user turn
    this.turns.push({ role: "user", content: text });

    // Add placeholder assistant turn
    const assistantTurn: ChatTurn = {
      role: "assistant",
      content: "",
      streaming: true,
      tokenCount: 0,
    };
    this.turns.push(assistantTurn);
    this._cd.markForCheck();

    // Build history for context (all completed turns)
    const messages = this.turns
      .filter((t) => !t.streaming)
      .map((t) => ({ role: t.role, content: t.content }));
    // Add the new user message
    messages.push({ role: "user", content: text });

    const request: StreamChatRequest = {
      clientConfig: this._clientConfig,
      chatCompletionConfig: { messages },
    };

    this._tracing.withChatSpan("stream-send", async () => {
      this._startStream(assistantTurn, request);
    });
  }

  /** Cancel an in-flight stream. */
  cancel(): void {
    if (!this.isStreaming) return;
    this._streamSub?.unsubscribe();
    this._streamSub = null;

    // Mark the last assistant turn as cancelled
    const last = this._lastAssistantTurn();
    if (last) {
      last.streaming = false;
      last.finishReason = "cancelled";
    }
    this._cd.markForCheck();
  }

  /** Clear conversation history and any active stream. */
  clear(): void {
    this.cancel();
    this.turns = [];
    this.error = null;
    this._cd.markForCheck();
  }

  // ── Private ────────────────────────────────────────────────────────

  private _startStream(assistantTurn: ChatTurn, request: StreamChatRequest): void {
    this._streamSub = this._streaming.streamChat(request).subscribe({
      next: (delta: string) => {
        assistantTurn.content += delta;
        assistantTurn.tokenCount = (assistantTurn.tokenCount ?? 0) + 1;
        this._cd.markForCheck();
        this._scrollToBottom();
      },

      error: (err: unknown) => {
        assistantTurn.streaming = false;
        assistantTurn.finishReason = "error";

        if (err instanceof StreamChatError) {
          this.error = `[${err.code}] ${err.message}`;
        } else {
          this.error = (err as Error).message ?? "Unknown streaming error";
        }

        this._streamSub = null;
        this._cd.markForCheck();
      },

      complete: () => {
        assistantTurn.streaming = false;
        assistantTurn.finishReason = assistantTurn.finishReason ?? "stop";
        this._streamSub = null;
        this._cd.markForCheck();
        this._scrollToBottom();
      },
    });
  }

  private _lastAssistantTurn(): ChatTurn | undefined {
    for (let i = this.turns.length - 1; i >= 0; i--) {
      if (this.turns[i].role === "assistant") return this.turns[i];
    }
    return undefined;
  }

  private _scrollToBottom(): void {
    try {
      this._messagesEnd?.nativeElement?.scrollIntoView({ behavior: "smooth" });
    } catch {
      // ViewChild may not be initialised during server-side rendering
    }
  }
}
