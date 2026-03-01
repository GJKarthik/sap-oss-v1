// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.SimilaritySearchError = void 0;
const CAPLLMPluginError_1 = require("./CAPLLMPluginError");
/**
 * Error thrown during similarity search operations.
 *
 * Covers invalid algorithm names, SQL identifier validation failures,
 * and embedding vector validation errors.
 */
class SimilaritySearchError extends CAPLLMPluginError_1.CAPLLMPluginError {
    constructor(message, code, details) {
        super(message, code, details);
        this.name = "SimilaritySearchError";
    }
}
exports.SimilaritySearchError = SimilaritySearchError;
//# sourceMappingURL=SimilaritySearchError.js.map