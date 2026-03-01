// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { CAPLLMPluginError } from "./CAPLLMPluginError";
/**
 * Error thrown during similarity search operations.
 *
 * Covers invalid algorithm names, SQL identifier validation failures,
 * and embedding vector validation errors.
 */
export declare class SimilaritySearchError extends CAPLLMPluginError {
    constructor(message: string, code: string, details?: Record<string, unknown>);
}
//# sourceMappingURL=SimilaritySearchError.d.ts.map