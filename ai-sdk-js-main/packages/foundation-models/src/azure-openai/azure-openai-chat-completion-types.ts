// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import type { AzureOpenAiCreateChatCompletionRequest } from './client/inference/schema/index.js';

/**
 * Azure OpenAI chat completion input parameters.
 */
export type AzureOpenAiChatCompletionParameters =
  AzureOpenAiCreateChatCompletionRequest;
