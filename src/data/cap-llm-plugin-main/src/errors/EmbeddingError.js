"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.EmbeddingError = void 0;
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
const CAPLLMPluginError_1 = require("./CAPLLMPluginError");
/**
 * Error thrown during embedding operations.
 *
 * Covers config validation failures and SDK embedding client errors.
 */
class EmbeddingError extends CAPLLMPluginError_1.CAPLLMPluginError {
    constructor(message, code, details) {
        super(message, code, details);
        this.name = "EmbeddingError";
    }
}
exports.EmbeddingError = EmbeddingError;
//# sourceMappingURL=EmbeddingError.js.map