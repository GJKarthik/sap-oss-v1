/**
 * cap-llm-plugin error class hierarchy.
 *
 * All plugin errors extend CAPLLMPluginError, which provides:
 *   - `code`: machine-readable error code string
 *   - `details`: optional structured context object
 *   - `message`: human-readable error description
 */
export { CAPLLMPluginError } from "./CAPLLMPluginError";
export { EmbeddingError } from "./EmbeddingError";
export { ChatCompletionError } from "./ChatCompletionError";
export { SimilaritySearchError } from "./SimilaritySearchError";
export { AnonymizationError } from "./AnonymizationError";
