/**
 * Example Angular component demonstrating typed client usage.
 *
 * This file shows how a consuming Angular application would use the
 * generated CAPLLMPluginService with full type safety.
 *
 * NOTE: This is a reference example, not a runnable app.
 * Copy into your Angular project and adjust imports as needed.
 */

import { Component } from "@angular/core";
import { firstValueFrom } from "rxjs";
import {
  CAPLLMPluginService,
  ChatMessage,
  EmbeddingConfig,
  ChatConfig,
  RagResponse,
  SimilaritySearchResult,
  GetHarmonizedChatCompletionRequest,
  LLMErrorDetail,
} from "../../generated/angular-client";
import { extractErrorDetail } from "./error.interceptor";

@Component({
  selector: "app-chat",
  template: `
    <div class="chat-container">
      <div class="messages">
        <div *ngFor="let msg of messages" [class]="msg.role">
          {{ msg.content }}
        </div>
      </div>
      <div class="input-row">
        <input [(ngModel)]="userInput" placeholder="Ask a question..." />
        <button (click)="sendMessage()" [disabled]="loading">Send</button>
      </div>
      <div *ngIf="error" class="error">{{ error.code }}: {{ error.message }}</div>
    </div>
  `,
})
export class ChatComponent {
  messages: ChatMessage[] = [];
  userInput = "";
  loading = false;
  error: LLMErrorDetail | null = null;

  // ── Config — type-safe, IDE autocomplete works ─────────────────────
  private embeddingConfig: EmbeddingConfig = {
    modelName: "text-embedding-ada-002",
    resourceGroup: "default",
  };

  private chatConfig: ChatConfig = {
    modelName: "gpt-4o",
    resourceGroup: "default",
  };

  constructor(private llm: CAPLLMPluginService) {}

  // ── Simple chat completion ─────────────────────────────────────────
  async sendMessage(): Promise<void> {
    if (!this.userInput.trim()) return;

    const userMsg: ChatMessage = { role: "user", content: this.userInput };
    this.messages.push(userMsg);
    this.userInput = "";
    this.loading = true;
    this.error = null;

    try {
      // Type-safe: getChatCompletionWithConfig expects GetChatCompletionRequest
      const response = await firstValueFrom(
        this.llm.getChatCompletionWithConfig({
          config: this.chatConfig,
          messages: this.messages,
        }),
      );

      // Response is typed as string (JSON-serialized SDK response)
      const parsed = JSON.parse(response);
      const assistantContent =
        parsed?.choices?.[0]?.message?.content ?? "No response";

      this.messages.push({ role: "assistant", content: assistantContent });
    } catch (err: unknown) {
      // extractErrorDetail handles HttpErrorResponse, LLMErrorDetail, and raw errors
      this.error = extractErrorDetail(err);
    } finally {
      this.loading = false;
    }
  }

  // ── RAG pipeline — fully typed request and response ────────────────
  async askWithContext(
    question: string,
    tableName: string,
  ): Promise<RagResponse | null> {
    try {
      // Type-safe: getRagResponse expects GetRagResponseRequest
      const ragResponse: RagResponse = await firstValueFrom(
        this.llm.getRagResponse({
          input: question,
          tableName,
          embeddingColumnName: "EMBEDDING",
          contentColumn: "TEXT_CONTENT",
          chatInstruction:
            "Answer the question based on the provided context.",
          embeddingConfig: this.embeddingConfig,
          chatConfig: this.chatConfig,
          topK: 5,
          algoName: "COSINE_SIMILARITY",
        }),
      );

      // ragResponse.additionalContents is typed as SimilaritySearchResult[]
      if (ragResponse.additionalContents) {
        for (const result of ragResponse.additionalContents) {
          // Type-safe access to PAGE_CONTENT and SCORE
          console.log(`[${result.SCORE}] ${result.PAGE_CONTENT}`);
        }
      }

      return ragResponse;
    } catch {
      return null;
    }
  }

  // ── Similarity search — typed array response ───────────────────────
  async searchSimilar(query: string): Promise<SimilaritySearchResult[]> {
    const embedding = await firstValueFrom(
      this.llm.getEmbeddingWithConfig({
        config: this.embeddingConfig,
        input: query,
      }),
    );

    // Parse embedding vector from SDK response
    const parsed = JSON.parse(embedding);
    const vector: number[] = parsed?.getEmbeddings?.[0]?.embedding ?? [];

    // Type-safe: similaritySearch returns Observable<SimilaritySearchResult[]>
    return firstValueFrom(
      this.llm.similaritySearch({
        tableName: "DOCUMENTS",
        embeddingColumnName: "EMBEDDING",
        contentColumn: "TEXT_CONTENT",
        embedding: JSON.stringify(vector),
        topK: 10,
      }),
    );
  }

  // ── Orchestration with flags — type-safe params ────────────────────
  async harmonizedChat(userMessage: string): Promise<string> {
    // GetHarmonizedChatCompletionRequest has typed fields
    const params: GetHarmonizedChatCompletionRequest = {
      clientConfig: JSON.stringify({
        promptTemplating: { model: { name: "gpt-4o" } },
      }),
      chatCompletionConfig: JSON.stringify({
        messages: [{ role: "user", content: userMessage }],
      }),
      getContent: true, // Return only the message content
    };

    return firstValueFrom(this.llm.getHarmonizedChatCompletion(params));
  }
}
