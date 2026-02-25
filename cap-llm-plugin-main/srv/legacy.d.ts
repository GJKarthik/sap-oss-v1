/**
 * Type declarations for legacy.js (deprecated methods).
 */
export function getEmbedding(input: unknown): Promise<number[]>;
export function getChatCompletion(payload: unknown): Promise<unknown>;
export function getRagResponse(
  getEmbeddingFn: (input: string) => Promise<number[]>,
  similaritySearchFn: (...args: unknown[]) => Promise<unknown[]>,
  getChatCompletionFn: (payload: unknown) => Promise<unknown>,
  input: string,
  tableName: string,
  embeddingColumnName: string,
  contentColumn: string,
  chatInstruction: string,
  context?: unknown,
  topK?: number,
  algoName?: string,
  chatParams?: unknown
): Promise<{ completion: unknown; additionalContents: unknown[] }>;
