// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import { CAPLLMPluginError } from "./CAPLLMPluginError";

/**
 * Error thrown during chat completion operations.
 *
 * Covers config validation failures, SDK OrchestrationClient errors,
 * and unsupported content filter types.
 */
export class ChatCompletionError extends CAPLLMPluginError {
  constructor(message: string, code: string, details?: Record<string, unknown>) {
    super(message, code, details);
    this.name = "ChatCompletionError";
  }
}
