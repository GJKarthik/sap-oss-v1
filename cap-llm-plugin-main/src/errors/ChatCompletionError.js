// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.ChatCompletionError = void 0;
const CAPLLMPluginError_1 = require("./CAPLLMPluginError");
/**
 * Error thrown during chat completion operations.
 *
 * Covers config validation failures, SDK OrchestrationClient errors,
 * and unsupported content filter types.
 */
class ChatCompletionError extends CAPLLMPluginError_1.CAPLLMPluginError {
    constructor(message, code, details) {
        super(message, code, details);
        this.name = "ChatCompletionError";
    }
}
exports.ChatCompletionError = ChatCompletionError;
//# sourceMappingURL=ChatCompletionError.js.map