// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Request and response transformers for vLLM API.
 * Converts between SDK format (camelCase) and API format (snake_case).
 */

import type {
  VllmChatRequest,
  VllmChatResponse,
  VllmChatMessage,
  VllmStreamChunk,
  VllmUsage,
  VllmToolCall,
} from './types.js';

// ============================================================================
// API Types (snake_case format used by vLLM/OpenAI API)
// ============================================================================

/**
 * API message format (snake_case).
 */
export interface ApiChatMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string;
  name?: string;
  tool_calls?: ApiToolCall[];
  tool_call_id?: string;
}

/**
 * API tool call format.
 */
export interface ApiToolCall {
  id: string;
  type: 'function';
  function: {
    name: string;
    arguments: string;
  };
}

/**
 * API chat request format.
 */
export interface ApiChatRequest {
  model: string;
  messages: ApiChatMessage[];
  temperature?: number;
  top_p?: number;
  top_k?: number;
  max_tokens?: number;
  stream?: boolean;
  stop?: string | string[];
  presence_penalty?: number;
  frequency_penalty?: number;
  n?: number;
  seed?: number;
  logprobs?: boolean;
  use_beam_search?: boolean;
  best_of?: number;
  min_tokens?: number;
  repetition_penalty?: number;
}

/**
 * API chat response format.
 */
export interface ApiChatResponse {
  id: string;
  object: 'chat.completion';
  created: number;
  model: string;
  choices: ApiChatChoice[];
  usage: ApiUsage;
}

/**
 * API chat choice format.
 */
export interface ApiChatChoice {
  index: number;
  message: ApiChatMessage;
  finish_reason: 'stop' | 'length' | 'tool_calls' | null;
  logprobs?: ApiLogprobs | null;
}

/**
 * API logprobs format.
 */
export interface ApiLogprobs {
  content: Array<{
    token: string;
    logprob: number;
    bytes?: number[];
    top_logprobs?: Array<{
      token: string;
      logprob: number;
      bytes?: number[];
    }>;
  }> | null;
}

/**
 * API usage format.
 */
export interface ApiUsage {
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
}

/**
 * API stream chunk format.
 */
export interface ApiStreamChunk {
  id: string;
  object: 'chat.completion.chunk';
  created: number;
  model: string;
  choices: ApiStreamChoice[];
}

/**
 * API stream choice format.
 */
export interface ApiStreamChoice {
  index: number;
  delta: {
    role?: 'assistant';
    content?: string;
    tool_calls?: ApiToolCall[];
  };
  finish_reason: 'stop' | 'length' | 'tool_calls' | null;
  logprobs?: ApiLogprobs | null;
}

// ============================================================================
// Request Transformers (SDK → API)
// ============================================================================

/**
 * Transforms SDK chat request to API format.
 */
export function transformChatRequest(request: VllmChatRequest, defaultModel: string): ApiChatRequest {
  const apiRequest: ApiChatRequest = {
    model: request.model ?? defaultModel,
    messages: request.messages.map(transformMessageToApi),
  };

  // Add optional parameters (only if defined)
  if (request.temperature !== undefined) apiRequest.temperature = request.temperature;
  if (request.topP !== undefined) apiRequest.top_p = request.topP;
  if (request.topK !== undefined) apiRequest.top_k = request.topK;
  if (request.maxTokens !== undefined) apiRequest.max_tokens = request.maxTokens;
  if (request.stream !== undefined) apiRequest.stream = request.stream;
  if (request.stop !== undefined) apiRequest.stop = request.stop;
  if (request.presencePenalty !== undefined) apiRequest.presence_penalty = request.presencePenalty;
  if (request.frequencyPenalty !== undefined) apiRequest.frequency_penalty = request.frequencyPenalty;
  if (request.n !== undefined) apiRequest.n = request.n;
  if (request.seed !== undefined) apiRequest.seed = request.seed;
  if (request.logprobs !== undefined) apiRequest.logprobs = request.logprobs;
  if (request.useBeamSearch !== undefined) apiRequest.use_beam_search = request.useBeamSearch;
  if (request.bestOf !== undefined) apiRequest.best_of = request.bestOf;
  if (request.minTokens !== undefined) apiRequest.min_tokens = request.minTokens;
  if (request.repetitionPenalty !== undefined) apiRequest.repetition_penalty = request.repetitionPenalty;

  return apiRequest;
}

/**
 * Transforms SDK message to API format.
 */
export function transformMessageToApi(message: VllmChatMessage): ApiChatMessage {
  const apiMessage: ApiChatMessage = {
    role: message.role,
    content: message.content,
  };

  if (message.name) apiMessage.name = message.name;
  if (message.toolCalls) apiMessage.tool_calls = message.toolCalls.map(transformToolCallToApi);
  if (message.toolCallId) apiMessage.tool_call_id = message.toolCallId;

  return apiMessage;
}

/**
 * Transforms SDK tool call to API format.
 */
export function transformToolCallToApi(toolCall: VllmToolCall): ApiToolCall {
  return {
    id: toolCall.id,
    type: toolCall.type,
    function: {
      name: toolCall.function.name,
      arguments: toolCall.function.arguments,
    },
  };
}

// ============================================================================
// Response Transformers (API → SDK)
// ============================================================================

/**
 * Transforms API chat response to SDK format.
 */
export function transformChatResponse(apiResponse: ApiChatResponse): VllmChatResponse {
  return {
    id: apiResponse.id,
    object: apiResponse.object,
    created: apiResponse.created,
    model: apiResponse.model,
    choices: apiResponse.choices.map(transformChoiceToSdk),
    usage: transformUsageToSdk(apiResponse.usage),
  };
}

/**
 * Transforms API choice to SDK format.
 */
export function transformChoiceToSdk(apiChoice: ApiChatChoice): {
  index: number;
  message: VllmChatMessage;
  finishReason: 'stop' | 'length' | 'tool_calls' | null;
  logprobs?: { content: Array<{ token: string; logprob: number; bytes?: number[]; topLogprobs?: Array<{ token: string; logprob: number; bytes?: number[] }> }> | null } | null;
} {
  return {
    index: apiChoice.index,
    message: transformMessageToSdk(apiChoice.message),
    finishReason: apiChoice.finish_reason,
    logprobs: apiChoice.logprobs ? transformLogprobsToSdk(apiChoice.logprobs) : null,
  };
}

/**
 * Transforms API message to SDK format.
 */
export function transformMessageToSdk(apiMessage: ApiChatMessage): VllmChatMessage {
  const message: VllmChatMessage = {
    role: apiMessage.role,
    content: apiMessage.content,
  };

  if (apiMessage.name) message.name = apiMessage.name;
  if (apiMessage.tool_calls) message.toolCalls = apiMessage.tool_calls.map(transformToolCallToSdk);
  if (apiMessage.tool_call_id) message.toolCallId = apiMessage.tool_call_id;

  return message;
}

/**
 * Transforms API tool call to SDK format.
 */
export function transformToolCallToSdk(apiToolCall: ApiToolCall): VllmToolCall {
  return {
    id: apiToolCall.id,
    type: apiToolCall.type,
    function: {
      name: apiToolCall.function.name,
      arguments: apiToolCall.function.arguments,
    },
  };
}

/**
 * Transforms API usage to SDK format.
 */
export function transformUsageToSdk(apiUsage: ApiUsage): VllmUsage {
  return {
    promptTokens: apiUsage.prompt_tokens,
    completionTokens: apiUsage.completion_tokens,
    totalTokens: apiUsage.total_tokens,
  };
}

/**
 * Transforms API logprobs to SDK format.
 */
export function transformLogprobsToSdk(apiLogprobs: ApiLogprobs): {
  content: Array<{
    token: string;
    logprob: number;
    bytes?: number[];
    topLogprobs?: Array<{ token: string; logprob: number; bytes?: number[] }>;
  }> | null;
} {
  if (!apiLogprobs.content) {
    return { content: null };
  }

  return {
    content: apiLogprobs.content.map((item) => ({
      token: item.token,
      logprob: item.logprob,
      bytes: item.bytes,
      topLogprobs: item.top_logprobs?.map((tp) => ({
        token: tp.token,
        logprob: tp.logprob,
        bytes: tp.bytes,
      })),
    })),
  };
}

/**
 * Transforms API stream chunk to SDK format.
 */
export function transformStreamChunk(apiChunk: ApiStreamChunk): VllmStreamChunk {
  return {
    id: apiChunk.id,
    object: apiChunk.object,
    created: apiChunk.created,
    model: apiChunk.model,
    choices: apiChunk.choices.map((choice) => ({
      index: choice.index,
      delta: {
        role: choice.delta.role,
        content: choice.delta.content,
        toolCalls: choice.delta.tool_calls?.map(transformToolCallToSdk),
      },
      finishReason: choice.finish_reason,
      logprobs: choice.logprobs ? transformLogprobsToSdk(choice.logprobs) : null,
    })),
  };
}