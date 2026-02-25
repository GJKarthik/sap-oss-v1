import { CAPLLMPluginError } from "./CAPLLMPluginError";

/**
 * Error thrown during similarity search operations.
 *
 * Covers invalid algorithm names, SQL identifier validation failures,
 * and embedding vector validation errors.
 */
export class SimilaritySearchError extends CAPLLMPluginError {
  constructor(message: string, code: string, details?: Record<string, unknown>) {
    super(message, code, details);
    this.name = "SimilaritySearchError";
  }
}
