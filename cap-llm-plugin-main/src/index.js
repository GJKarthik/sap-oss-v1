"use strict";
/**
 * cap-llm-plugin — Public API type exports.
 *
 * Consumers can import types directly from the package:
 *
 *   import type { EmbeddingConfig, ChatConfig, RagResponse } from "cap-llm-plugin";
 *
 * Or from the explicit path:
 *
 *   import type { EmbeddingConfig } from "cap-llm-plugin/src/types";
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.toErrorResponse = exports.ERROR_HTTP_STATUS = exports.AnonymizationError = exports.SimilaritySearchError = exports.ChatCompletionError = exports.EmbeddingError = exports.CAPLLMPluginError = void 0;
// ── Error classes ────────────────────────────────────────────────────
var errors_1 = require("./errors");
Object.defineProperty(exports, "CAPLLMPluginError", { enumerable: true, get: function () { return errors_1.CAPLLMPluginError; } });
Object.defineProperty(exports, "EmbeddingError", { enumerable: true, get: function () { return errors_1.EmbeddingError; } });
Object.defineProperty(exports, "ChatCompletionError", { enumerable: true, get: function () { return errors_1.ChatCompletionError; } });
Object.defineProperty(exports, "SimilaritySearchError", { enumerable: true, get: function () { return errors_1.SimilaritySearchError; } });
Object.defineProperty(exports, "AnonymizationError", { enumerable: true, get: function () { return errors_1.AnonymizationError; } });
Object.defineProperty(exports, "ERROR_HTTP_STATUS", { enumerable: true, get: function () { return errors_1.ERROR_HTTP_STATUS; } });
Object.defineProperty(exports, "toErrorResponse", { enumerable: true, get: function () { return errors_1.toErrorResponse; } });
//# sourceMappingURL=index.js.map