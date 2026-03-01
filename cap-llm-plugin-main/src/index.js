// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
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
exports.TracingSpanStatus = exports.addEventToActiveSpan = exports.withFilterSpan = exports.withRagSpan = exports.withChatSpan = exports.withSpan = exports.injectTraceContextHeaders = exports.createOtelMiddleware = exports._resetTracerCache = exports.SpanStatusCode = exports.getTracer = exports.toErrorResponse = exports.ERROR_HTTP_STATUS = exports.AnonymizationError = exports.SimilaritySearchError = exports.ChatCompletionError = exports.EmbeddingError = exports.CAPLLMPluginError = void 0;
// ── Error classes ────────────────────────────────────────────────────
var errors_1 = require("./errors");
Object.defineProperty(exports, "CAPLLMPluginError", { enumerable: true, get: function () { return errors_1.CAPLLMPluginError; } });
Object.defineProperty(exports, "EmbeddingError", { enumerable: true, get: function () { return errors_1.EmbeddingError; } });
Object.defineProperty(exports, "ChatCompletionError", { enumerable: true, get: function () { return errors_1.ChatCompletionError; } });
Object.defineProperty(exports, "SimilaritySearchError", { enumerable: true, get: function () { return errors_1.SimilaritySearchError; } });
Object.defineProperty(exports, "AnonymizationError", { enumerable: true, get: function () { return errors_1.AnonymizationError; } });
Object.defineProperty(exports, "ERROR_HTTP_STATUS", { enumerable: true, get: function () { return errors_1.ERROR_HTTP_STATUS; } });
Object.defineProperty(exports, "toErrorResponse", { enumerable: true, get: function () { return errors_1.toErrorResponse; } });
// ── Telemetry ────────────────────────────────────────────────────────
var tracer_1 = require("./telemetry/tracer");
Object.defineProperty(exports, "getTracer", { enumerable: true, get: function () { return tracer_1.getTracer; } });
Object.defineProperty(exports, "SpanStatusCode", { enumerable: true, get: function () { return tracer_1.SpanStatusCode; } });
Object.defineProperty(exports, "_resetTracerCache", { enumerable: true, get: function () { return tracer_1._resetTracerCache; } });
var ai_sdk_middleware_1 = require("./telemetry/ai-sdk-middleware");
Object.defineProperty(exports, "createOtelMiddleware", { enumerable: true, get: function () { return ai_sdk_middleware_1.createOtelMiddleware; } });
var angular_tracing_1 = require("./telemetry/angular-tracing");
Object.defineProperty(exports, "injectTraceContextHeaders", { enumerable: true, get: function () { return angular_tracing_1.injectTraceContextHeaders; } });
Object.defineProperty(exports, "withSpan", { enumerable: true, get: function () { return angular_tracing_1.withSpan; } });
Object.defineProperty(exports, "withChatSpan", { enumerable: true, get: function () { return angular_tracing_1.withChatSpan; } });
Object.defineProperty(exports, "withRagSpan", { enumerable: true, get: function () { return angular_tracing_1.withRagSpan; } });
Object.defineProperty(exports, "withFilterSpan", { enumerable: true, get: function () { return angular_tracing_1.withFilterSpan; } });
Object.defineProperty(exports, "addEventToActiveSpan", { enumerable: true, get: function () { return angular_tracing_1.addEventToActiveSpan; } });
Object.defineProperty(exports, "TracingSpanStatus", { enumerable: true, get: function () { return angular_tracing_1.TracingSpanStatus; } });
//# sourceMappingURL=index.js.map