/**
 * CAP LLM Plugin — Angular HTTP Client Service
 *
 * Typed Angular service generated from docs/api/openapi.yaml.
 * DO NOT EDIT MANUALLY — regenerate with `npm run generate:client`.
 *
 * Usage:
 *   import { CAPLLMPluginService } from 'cap-llm-plugin/generated/angular-client';
 *
 *   @Component({ ... })
 *   export class MyComponent {
 *     constructor(private llm: CAPLLMPluginService) {}
 *
 *     async onChat() {
 *       const response = await firstValueFrom(
 *         this.llm.getChatCompletionWithConfig({
 *           config: { modelName: 'gpt-4o', resourceGroup: 'default' },
 *           messages: [{ role: 'user', content: 'Hello' }],
 *         })
 *       );
 *     }
 *   }
 */

import { Injectable } from "@angular/core";
import { HttpClient } from "@angular/common/http";
import { Observable } from "rxjs";

import type {
  GetEmbeddingRequest,
  GetChatCompletionRequest,
  GetRagResponseRequest,
  RagResponse,
  SimilaritySearchRequest,
  SimilaritySearchResult,
  GetAnonymizedDataRequest,
  GetHarmonizedChatCompletionRequest,
  GetContentFiltersRequest,
} from "./models";

/**
 * Typed Angular HTTP client for the CAP LLM Plugin service.
 *
 * All methods return `Observable`s. Use `firstValueFrom()` for async/await.
 * Errors are returned as `ErrorResponse` (see models.ts).
 */
@Injectable({ providedIn: "root" })
export class CAPLLMPluginService {
  private readonly basePath: string;

  constructor(private http: HttpClient) {
    this.basePath = "/odata/v4/cap-llm-plugin";
  }

  // ── Embedding ──────────────────────────────────────────────────────

  /** Generate vector embeddings for the given input text. */
  getEmbeddingWithConfig(body: GetEmbeddingRequest): Observable<string> {
    return this.http.post<string>(
      `${this.basePath}/getEmbeddingWithConfig`,
      body,
    );
  }

  // ── Chat Completion ────────────────────────────────────────────────

  /** Perform a chat completion request via the Orchestration SDK. */
  getChatCompletionWithConfig(
    body: GetChatCompletionRequest,
  ): Observable<string> {
    return this.http.post<string>(
      `${this.basePath}/getChatCompletionWithConfig`,
      body,
    );
  }

  // ── RAG Pipeline ───────────────────────────────────────────────────

  /** Full RAG pipeline: embed → search → complete. */
  getRagResponse(body: GetRagResponseRequest): Observable<RagResponse> {
    return this.http.post<RagResponse>(
      `${this.basePath}/getRagResponse`,
      body,
    );
  }

  // ── Similarity Search ──────────────────────────────────────────────

  /** Perform vector similarity search on a HANA Cloud table. */
  similaritySearch(
    body: SimilaritySearchRequest,
  ): Observable<SimilaritySearchResult[]> {
    return this.http.post<SimilaritySearchResult[]>(
      `${this.basePath}/similaritySearch`,
      body,
    );
  }

  // ── Anonymization ──────────────────────────────────────────────────

  /** Retrieve anonymized data from a HANA anonymized view. */
  getAnonymizedData(body: GetAnonymizedDataRequest): Observable<string> {
    return this.http.post<string>(
      `${this.basePath}/getAnonymizedData`,
      body,
    );
  }

  // ── Orchestration ──────────────────────────────────────────────────

  /** Chat completion with OrchestrationClient and optional response extraction. */
  getHarmonizedChatCompletion(
    body: GetHarmonizedChatCompletionRequest,
  ): Observable<string> {
    return this.http.post<string>(
      `${this.basePath}/getHarmonizedChatCompletion`,
      body,
    );
  }

  /** Build a content safety filter for use with the Orchestration Service. */
  getContentFilters(body: GetContentFiltersRequest): Observable<string> {
    return this.http.post<string>(
      `${this.basePath}/getContentFilters`,
      body,
    );
  }
}
