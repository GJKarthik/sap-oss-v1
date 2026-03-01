// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { CAPLLMPluginError } from "./CAPLLMPluginError";

/**
 * Error thrown during embedding operations.
 *
 * Covers config validation failures and SDK embedding client errors.
 */
export class EmbeddingError extends CAPLLMPluginError {
  constructor(message: string, code: string, details?: Record<string, unknown>) {
    super(message, code, details);
    this.name = "EmbeddingError";
  }
}
