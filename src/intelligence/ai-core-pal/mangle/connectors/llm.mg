// ============================================================================
// LLM Gateway Connector Schema - Shared contract for all BTP services
// ============================================================================
// OpenAI-compatible LLM gateway interface used across BTP services.

// --- Gateway Configuration ---
Decl llm_gateway_config(
    service_id: String,          // BTP service using this config
    endpoint: String,            // Gateway endpoint URL
    default_model: String,       // Default model to use
    credential_ref: String,      // BTP destination or API key ref
    timeout_ms: i32,             // Request timeout
    max_retries: i32             // Max retry attempts
).

// --- Model Registry ---
Decl llm_model(
    model_id: String,            // e.g., gpt-4o, claude-3
    provider: String,            // openai, anthropic, azure, sap
    context_window: i32,         // Max tokens
    input_cost_per_1k: f64,      // Cost in USD
    output_cost_per_1k: f64,
    supports_tools: i32,         // 1 = true, 0 = false
    supports_vision: i32,
    supports_streaming: i32
).

// --- Chat Completion Request ---
Decl llm_request(
    request_id: String,
    service_id: String,
    model: String,
    messages: String,            // JSON array of messages
    temperature: f64,
    max_tokens: i32,
    tools: String,               // JSON array of tool definitions
    tool_choice: String,         // auto, none, required, or specific
    requested_at: i64
).

// --- Chat Completion Response ---
Decl llm_response(
    request_id: String,
    status: String,              // success, error, timeout, rate_limited
    content: String,             // Response content
    tool_calls: String,          // JSON array of tool calls
    finish_reason: String,       // stop, tool_calls, length, content_filter
    input_tokens: i32,
    output_tokens: i32,
    duration_ms: i64
).

// --- Streaming Response ---
Decl llm_stream_chunk(
    request_id: String,
    chunk_index: i32,
    delta_content: String,
    delta_tool_calls: String,
    received_at: i64
).

// --- Tool Call Tracking ---
Decl llm_tool_call(
    call_id: String,
    request_id: String,
    tool_name: String,
    arguments: String,           // JSON object
    status: String,              // pending, executing, completed, failed
    result: String,
    duration_ms: i64
).

// --- Embedding Request ---
Decl llm_embedding_request(
    request_id: String,
    service_id: String,
    model: String,
    input: String,               // Text or JSON array of texts
    dimensions: i32,             // Optional output dimensions
    requested_at: i64
).

Decl llm_embedding_response(
    request_id: String,
    status: String,
    embeddings_ref: String,      // TOON pointer to vectors
    total_tokens: i32,
    duration_ms: i64
).

// --- Rate Limiting ---
Decl llm_rate_limit(
    service_id: String,
    model: String,
    requests_per_minute: i32,
    tokens_per_minute: i32,
    current_requests: i32,
    current_tokens: i32,
    reset_at: i64
).

// --- Usage Tracking ---
Decl llm_usage(
    service_id: String,
    model: String,
    date: String,                // YYYY-MM-DD
    total_requests: i32,
    total_input_tokens: i64,
    total_output_tokens: i64,
    total_cost_usd: f64
).

// ============================================================================
// Rules - LLM Operations
// ============================================================================

// Gateway is available for a model
llm_available(ServiceId, Model) :-
    llm_gateway_config(ServiceId, _, DefaultModel, _, _, _),
    llm_model(Model, _, _, _, _, _, _, _),
    (Model = DefaultModel ; llm_model_override(ServiceId, Model)).

// Model supports tools
model_supports_tools(Model) :-
    llm_model(Model, _, _, _, _, 1, _, _).

// Model supports vision
model_supports_vision(Model) :-
    llm_model(Model, _, _, _, _, _, 1, _).

// Model supports streaming
model_supports_streaming(Model) :-
    llm_model(Model, _, _, _, _, _, _, 1).

// Check rate limit not exceeded
rate_limit_ok(ServiceId, Model) :-
    llm_rate_limit(ServiceId, Model, RpmLimit, _, CurrentRpm, _, _),
    CurrentRpm < RpmLimit.

// Calculate estimated cost for request
estimate_cost(Model, InputTokens, OutputTokens, Cost) :-
    llm_model(Model, _, _, InputCost, OutputCost, _, _, _),
    Cost = (InputTokens * InputCost / 1000.0) + (OutputTokens * OutputCost / 1000.0).

// Request successful
request_succeeded(RequestId) :-
    llm_response(RequestId, "success", _, _, _, _, _, _).

// Request had tool calls
request_has_tool_calls(RequestId) :-
    llm_response(RequestId, "success", _, ToolCalls, "tool_calls", _, _, _),
    ToolCalls != "[]".

// All tool calls completed for request
all_tools_completed(RequestId) :-
    request_has_tool_calls(RequestId),
    not(llm_tool_call(_, RequestId, _, _, "pending", _, _)),
    not(llm_tool_call(_, RequestId, _, _, "executing", _, _)).

// Get total tokens for request
request_total_tokens(RequestId, Total) :-
    llm_response(RequestId, _, _, _, _, InputTok, OutputTok, _),
    Total = InputTok + OutputTok.