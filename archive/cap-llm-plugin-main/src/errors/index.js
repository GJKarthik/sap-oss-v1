"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.toErrorResponse = exports.ERROR_HTTP_STATUS = exports.AnonymizationError = exports.SimilaritySearchError = exports.ChatCompletionError = exports.EmbeddingError = exports.CAPLLMPluginError = void 0;
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * cap-llm-plugin error class hierarchy.
 *
 * All plugin errors extend CAPLLMPluginError, which provides:
 *   - `code`: machine-readable error code string
 *   - `details`: optional structured context object
 *   - `message`: human-readable error description
 */
var CAPLLMPluginError_1 = require("./CAPLLMPluginError");
Object.defineProperty(exports, "CAPLLMPluginError", { enumerable: true, get: function () { return CAPLLMPluginError_1.CAPLLMPluginError; } });
var EmbeddingError_1 = require("./EmbeddingError");
Object.defineProperty(exports, "EmbeddingError", { enumerable: true, get: function () { return EmbeddingError_1.EmbeddingError; } });
var ChatCompletionError_1 = require("./ChatCompletionError");
Object.defineProperty(exports, "ChatCompletionError", { enumerable: true, get: function () { return ChatCompletionError_1.ChatCompletionError; } });
var SimilaritySearchError_1 = require("./SimilaritySearchError");
Object.defineProperty(exports, "SimilaritySearchError", { enumerable: true, get: function () { return SimilaritySearchError_1.SimilaritySearchError; } });
var AnonymizationError_1 = require("./AnonymizationError");
Object.defineProperty(exports, "AnonymizationError", { enumerable: true, get: function () { return AnonymizationError_1.AnonymizationError; } });
var LLMErrorResponse_1 = require("./LLMErrorResponse");
Object.defineProperty(exports, "ERROR_HTTP_STATUS", { enumerable: true, get: function () { return LLMErrorResponse_1.ERROR_HTTP_STATUS; } });
Object.defineProperty(exports, "toErrorResponse", { enumerable: true, get: function () { return LLMErrorResponse_1.toErrorResponse; } });
//# sourceMappingURL=index.js.map