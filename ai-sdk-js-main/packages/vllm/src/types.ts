/**
 * Type definitions for vLLM integration.
 */

// ============================================================================
// Configuration Types
// ============================================================================

/**
 * Configuration for vLLM client connection.
 */
export interface VllmConfig {
  /**
   * vLLM server endpoint URL.
   * @example "http://localhost:8000"
   */
  endpoint: string;

  /**
   * Model identifier loaded in vLLM.
   * @example "meta-llama/Llama-3.1-70B-Instruct"
   */
  model: string;

  /**
   * Optional API key for authentication.
   * vLLM doesn't require authentication by default.
   */
  apiKey?: string;

  /**
   * Request timeout in milliseconds.
   * @default 60000
   */
  timeout?: number;

  /**
   * Maximum number of retry attempts.
   * @default 3
   */
  maxRetries?: number;

  /**
   * Custom headers to include in requests.
   */
  headers?: Record<string, string>;

  /**
   * Enable debug logging.
   * @default false
   */
  debug?: boolean;
}

// ============================================================================
// Chat Types
// ============================================================================

/**
 * Chat message format.
 */
export interface VllmChatMessage {
  /**
   * Role of the message sender.
   */
  role: 'system' | 'user' | 'assistant' | 'tool';

  /**
   * Message content.
   */
  content: string;

  /**
   * Optional name for the participant.
   */
  name?: string;

  /**
   * Tool calls (for assistant messages).
   */
  toolCalls?: VllmToolCall[];

  /**
   * Tool call ID (for tool responses).
   */
  toolCallId?: string;
}

/**
 * Tool call information.
 */
export interface VllmToolCall {
  /**
   * Unique identifier for the tool call.
   */
  id: string;

  /**
   * Type of tool (currently only "function").
   */
  type: 'function';

  /**
   * Function call details.
   */
  function: {
    /**
     * Name of the function to call.
     */
    name: string;

    /**
     * Arguments as a JSON string.
     */
    arguments: string;
  };
}

/**
 * Chat completion request parameters.
 */
export interface VllmChatRequest {
  /**
   * List of messages in the conversation.
   */
  messages: VllmChatMessage[];

  /**
   * Override the model specified in config.
   */
  model?: string;

  /**
   * Sampling temperature (0-2).
   * @default 1.0
   */
  temperature?: number;

  /**
   * Top-p (nucleus) sampling.
   * @default 1.0
   */
  topP?: number;

  /**
   * Top-k sampling (vLLM-specific).
   */
  topK?: number;

  /**
   * Maximum tokens to generate.
   */
  maxTokens?: number;

  /**
   * Enable streaming response.
   * @default false
   */
  stream?: boolean;

  /**
   * Stop sequences.
   */
  stop?: string | string[];

  /**
   * Presence penalty (-2 to 2).
   */
  presencePenalty?: number;

  /**
   * Frequency penalty (-2 to 2).
   */
  frequencyPenalty?: number;

  /**
   * Number of completions to generate.
   * @default 1
   */
  n?: number;

  /**
   * Random seed for deterministic generation.
   */
  seed?: number;

  /**
   * Return log probabilities.
   */
  logprobs?: boolean;

  /**
   * vLLM-specific: use beam search.
   */
  useBeamSearch?: boolean;

  /**
   * vLLM-specific: best_of parameter.
   */
  bestOf?: number;

  /**
   * vLLM-specific: minimum tokens to generate.
   */
  minTokens?: number;

  /**
   * vLLM-specific: repetition penalty.
   */
  repetitionPenalty?: number;
}

/**
 * Chat completion response.
 */
export interface VllmChatResponse {
  /**
   * Unique response identifier.
   */
  id: string;

  /**
   * Object type (always "chat.completion").
   */
  object: 'chat.completion';

  /**
   * Unix timestamp of creation.
   */
  created: number;

  /**
   * Model used for completion.
   */
  model: string;

  /**
   * List of completion choices.
   */
  choices: VllmChatChoice[];

  /**
   * Token usage statistics.
   */
  usage: VllmUsage;
}

/**
 * Individual completion choice.
 */
export interface VllmChatChoice {
  /**
   * Choice index.
   */
  index: number;

  /**
   * Generated message.
   */
  message: VllmChatMessage;

  /**
   * Reason for completion.
   */
  finishReason: 'stop' | 'length' | 'tool_calls' | null;

  /**
   * Log probabilities (if requested).
   */
  logprobs?: VllmLogprobs | null;
}

/**
 * Log probability information.
 */
export interface VllmLogprobs {
  /**
   * Content log probabilities.
   */
  content: Array<{
    token: string;
    logprob: number;
    bytes?: number[];
    topLogprobs?: Array<{
      token: string;
      logprob: number;
      bytes?: number[];
    }>;
  }> | null;
}

/**
 * Token usage statistics.
 */
export interface VllmUsage {
  /**
   * Tokens in the prompt.
   */
  promptTokens: number;

  /**
   * Tokens in the completion.
   */
  completionTokens: number;

  /**
   * Total tokens used.
   */
  totalTokens: number;
}

// ============================================================================
// Streaming Types
// ============================================================================

/**
 * Streaming response chunk.
 */
export interface VllmStreamChunk {
  /**
   * Chunk identifier.
   */
  id: string;

  /**
   * Object type (always "chat.completion.chunk").
   */
  object: 'chat.completion.chunk';

  /**
   * Unix timestamp of creation.
   */
  created: number;

  /**
   * Model used for completion.
   */
  model: string;

  /**
   * List of delta choices.
   */
  choices: VllmStreamChoice[];
}

/**
 * Streaming choice delta.
 */
export interface VllmStreamChoice {
  /**
   * Choice index.
   */
  index: number;

  /**
   * Content delta.
   */
  delta: {
    role?: 'assistant';
    content?: string;
    toolCalls?: VllmToolCall[];
  };

  /**
   * Reason for completion (null until done).
   */
  finishReason: 'stop' | 'length' | 'tool_calls' | null;

  /**
   * Log probabilities (if requested).
   */
  logprobs?: VllmLogprobs | null;
}

// ============================================================================
// Completion Types (Text Completion API)
// ============================================================================

/**
 * Text completion request.
 */
export interface VllmCompletionRequest {
  /**
   * Prompt text.
   */
  prompt: string | string[];

  /**
   * Model to use.
   */
  model?: string;

  /**
   * Maximum tokens to generate.
   */
  maxTokens?: number;

  /**
   * Sampling temperature.
   */
  temperature?: number;

  /**
   * Top-p sampling.
   */
  topP?: number;

  /**
   * Top-k sampling.
   */
  topK?: number;

  /**
   * Stop sequences.
   */
  stop?: string | string[];

  /**
   * Enable streaming.
   */
  stream?: boolean;

  /**
   * Random seed.
   */
  seed?: number;

  /**
   * Echo prompt in response.
   */
  echo?: boolean;
}

/**
 * Text completion response.
 */
export interface VllmCompletionResponse {
  /**
   * Unique response identifier.
   */
  id: string;

  /**
   * Object type.
   */
  object: 'text_completion';

  /**
   * Unix timestamp.
   */
  created: number;

  /**
   * Model used.
   */
  model: string;

  /**
   * Completion choices.
   */
  choices: Array<{
    text: string;
    index: number;
    logprobs: VllmLogprobs | null;
    finishReason: 'stop' | 'length' | null;
  }>;

  /**
   * Token usage.
   */
  usage: VllmUsage;
}

// ============================================================================
// Embedding Types
// ============================================================================

/**
 * Embedding request.
 */
export interface VllmEmbeddingRequest {
  /**
   * Input text(s) to embed.
   */
  input: string | string[];

  /**
   * Model to use.
   */
  model?: string;

  /**
   * Encoding format.
   */
  encodingFormat?: 'float' | 'base64';
}

/**
 * Embedding response.
 */
export interface VllmEmbeddingResponse {
  /**
   * Object type.
   */
  object: 'list';

  /**
   * Embedding data.
   */
  data: Array<{
    object: 'embedding';
    index: number;
    embedding: number[];
  }>;

  /**
   * Model used.
   */
  model: string;

  /**
   * Token usage.
   */
  usage: {
    promptTokens: number;
    totalTokens: number;
  };
}

// ============================================================================
// Model and Health Types
// ============================================================================

/**
 * Model information.
 */
export interface VllmModel {
  /**
   * Model identifier.
   */
  id: string;

  /**
   * Object type.
   */
  object: 'model';

  /**
   * Unix timestamp of creation.
   */
  created: number;

  /**
   * Owner/organization.
   */
  ownedBy: string;

  /**
   * Model capabilities.
   */
  capabilities?: {
    chat: boolean;
    completion: boolean;
    embedding: boolean;
  };
}

/**
 * Health status response.
 */
export interface VllmHealthStatus {
  /**
   * Whether the server is healthy.
   */
  healthy: boolean;

  /**
   * Server status message.
   */
  status: string;

  /**
   * Loaded models.
   */
  models?: string[];

  /**
   * Server version.
   */
  version?: string;

  /**
   * GPU utilization (if available).
   */
  gpuUtilization?: number;

  /**
   * Number of pending requests.
   */
  pendingRequests?: number;

  /**
   * Timestamp of health check.
   */
  timestamp: number;
}