"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.AnonymizationError = void 0;
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
const CAPLLMPluginError_1 = require("./CAPLLMPluginError");
/**
 * Error thrown during anonymization operations.
 *
 * Covers entity-not-found, missing sequence column, and invalid
 * sequence ID errors in getAnonymizedData.
 */
class AnonymizationError extends CAPLLMPluginError_1.CAPLLMPluginError {
    constructor(message, code, details) {
        super(message, code, details);
        this.name = "AnonymizationError";
    }
}
exports.AnonymizationError = AnonymizationError;
//# sourceMappingURL=AnonymizationError.js.map