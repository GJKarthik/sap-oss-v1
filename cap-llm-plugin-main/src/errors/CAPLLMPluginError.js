"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.CAPLLMPluginError = void 0;
/**
 * Base error class for all cap-llm-plugin errors.
 *
 * Provides a structured error with a machine-readable `code` and
 * optional `details` object for additional context.
 */
class CAPLLMPluginError extends Error {
    constructor(message, code, details) {
        super(message);
        this.name = "CAPLLMPluginError";
        this.code = code;
        this.details = details;
        Error.captureStackTrace(this, this.constructor);
    }
}
exports.CAPLLMPluginError = CAPLLMPluginError;
//# sourceMappingURL=CAPLLMPluginError.js.map