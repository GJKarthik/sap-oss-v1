// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { CAPLLMPluginError } from "./CAPLLMPluginError";
/**
 * Error thrown during anonymization operations.
 *
 * Covers entity-not-found, missing sequence column, and invalid
 * sequence ID errors in getAnonymizedData.
 */
export declare class AnonymizationError extends CAPLLMPluginError {
    constructor(message: string, code: string, details?: Record<string, unknown>);
}
//# sourceMappingURL=AnonymizationError.d.ts.map