import { CAPLLMPluginError } from "./CAPLLMPluginError";
/**
 * Error thrown during chat completion operations.
 *
 * Covers config validation failures, SDK OrchestrationClient errors,
 * and unsupported content filter types.
 */
export declare class ChatCompletionError extends CAPLLMPluginError {
    constructor(message: string, code: string, details?: Record<string, unknown>);
}
//# sourceMappingURL=ChatCompletionError.d.ts.map