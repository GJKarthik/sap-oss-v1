//! OpenAI API Types
//!
//! Type definitions for OpenAI API compatibility with local LLM backends.

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

// ============================================================================
// Chat Completion Types
// ============================================================================

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    name: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

// ============================================================================
// Function Calling / Tool Use Types
// ============================================================================

pub const FunctionDefinition = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    parameters: ?[]const u8 = null, // JSON schema as string
};

pub const Tool = struct {
    type: []const u8, // "function"
    function: FunctionDefinition,
};

pub const FunctionCall = struct {
    name: []const u8,
    arguments: []const u8, // JSON string
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8, // "function"
    function: FunctionCall,
};

pub const ResponseFormat = struct {
    type: []const u8, // "text" or "json_object"
};

// ============================================================================
// Logprobs Types
// ============================================================================

pub const TopLogprob = struct {
    token: []const u8,
    logprob: f64,
    bytes: ?[]const u8 = null,
};

pub const TokenLogprob = struct {
    token: []const u8,
    logprob: f64,
    bytes: ?[]const u8 = null,
    top_logprobs: ?[]const TopLogprob = null,
};

pub const ChoiceLogprobs = struct {
    content: ?[]const TokenLogprob = null,
};

pub const ChatCompletionRequest = struct {
    model: []const u8,
    messages: []const Message,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    max_tokens: ?u32 = null,
    stream: ?bool = null,
    stop: ?[]const []const u8 = null,
    presence_penalty: ?f32 = null,
    frequency_penalty: ?f32 = null,
    // OpenAI additions
    n: ?u32 = null, // Number of completions to generate
    seed: ?i64 = null, // Reproducibility seed
    logprobs: ?bool = null, // Return log probabilities
    top_logprobs: ?u32 = null, // How many top logprobs per token (0-20)
    response_format: ?ResponseFormat = null, // json_object / text
    tools: ?[]const Tool = null, // Function calling tools
    tool_choice: ?[]const u8 = null, // "none", "auto", or function name
    user: ?[]const u8 = null, // End-user identifier
};

pub const ChatCompletionChoice = struct {
    index: u32,
    message: Message,
    finish_reason: ?[]const u8,
    logprobs: ?ChoiceLogprobs = null,
};

pub const UsageDetails = struct {
    cached_tokens: u32 = 0,
    reasoning_tokens: u32 = 0,
};

pub const Usage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
    prompt_tokens_details: ?UsageDetails = null,
    completion_tokens_details: ?UsageDetails = null,
};

pub const ChatCompletionResponse = struct {
    id: []const u8,
    object: []const u8,
    created: i64,
    model: []const u8,
    choices: []const ChatCompletionChoice,
    usage: Usage,
    system_fingerprint: ?[]const u8 = null,
};

// ============================================================================
// Streaming Types
// ============================================================================

pub const Delta = struct {
    role: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

pub const StreamChoice = struct {
    index: u32,
    delta: Delta,
    finish_reason: ?[]const u8 = null,
};

pub const ChatCompletionChunk = struct {
    id: []const u8,
    object: []const u8,
    created: i64,
    model: []const u8,
    choices: []const StreamChoice,
};

// ============================================================================
// Completions Types (Legacy)
// ============================================================================

pub const CompletionRequest = struct {
    model: []const u8,
    prompt: []const u8,
    max_tokens: ?u32 = null,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    stop: ?[]const []const u8 = null,
    stream: ?bool = null,
};

pub const CompletionChoice = struct {
    text: []const u8,
    index: u32,
    finish_reason: ?[]const u8,
};

pub const CompletionResponse = struct {
    id: []const u8,
    object: []const u8,
    created: i64,
    model: []const u8,
    choices: []const CompletionChoice,
    usage: Usage,
};

// ============================================================================
// Embeddings Types
// ============================================================================

pub const EmbeddingRequest = struct {
    model: []const u8,
    input: []const u8,
};

pub const EmbeddingData = struct {
    object: []const u8,
    embedding: []const f32,
    index: u32,
};

pub const EmbeddingResponse = struct {
    object: []const u8,
    data: []const EmbeddingData,
    model: []const u8,
    usage: struct {
        prompt_tokens: u32,
        total_tokens: u32,
    },
};

// ============================================================================
// Models Types
// ============================================================================

pub const Model = struct {
    id: []const u8,
    object: []const u8,
    created: i64,
    owned_by: []const u8,
};

pub const ModelsResponse = struct {
    object: []const u8,
    data: []const Model,
};

// ============================================================================
// Audio Types (Whisper / TTS)
// ============================================================================

pub const AudioTranscriptionRequest = struct {
    file: []const u8, // Binary audio data (multipart)
    model: []const u8,
    language: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    response_format: ?[]const u8 = null, // json, text, srt, vtt
    temperature: ?f32 = null,
};

pub const AudioTranscriptionResponse = struct {
    text: []const u8,
};

// ============================================================================
// Images Types (DALL-E)
// ============================================================================

pub const ImageGenerationRequest = struct {
    prompt: []const u8,
    model: ?[]const u8 = null,
    n: ?u32 = null,
    size: ?[]const u8 = null, // "256x256", "512x512", "1024x1024"
    response_format: ?[]const u8 = null, // "url" or "b64_json"
};

pub const ImageData = struct {
    url: ?[]const u8 = null,
    b64_json: ?[]const u8 = null,
    revised_prompt: ?[]const u8 = null,
};

pub const ImageGenerationResponse = struct {
    created: i64,
    data: []const ImageData,
};

// ============================================================================
// Files Types
// ============================================================================

pub const FileObject = struct {
    id: []const u8,
    object: []const u8,
    bytes: u64,
    created_at: i64,
    filename: []const u8,
    purpose: []const u8,
};

pub const FileListResponse = struct {
    object: []const u8,
    data: []const FileObject,
};

// ============================================================================
// Fine-Tuning Types
// ============================================================================

pub const FineTuningJobRequest = struct {
    training_file: []const u8,
    model: []const u8,
    hyperparameters: ?struct {
        n_epochs: ?u32 = null,
        batch_size: ?u32 = null,
        learning_rate_multiplier: ?f32 = null,
    } = null,
    suffix: ?[]const u8 = null,
    validation_file: ?[]const u8 = null,
};

pub const FineTuningJob = struct {
    id: []const u8,
    object: []const u8,
    model: []const u8,
    created_at: i64,
    status: []const u8, // "validating_files", "queued", "running", "succeeded", "failed", "cancelled"
    training_file: []const u8,
    fine_tuned_model: ?[]const u8 = null,
};

pub const FineTuningJobListResponse = struct {
    object: []const u8,
    data: []const FineTuningJob,
    has_more: bool,
};

// ============================================================================
// Moderations Types
// ============================================================================

pub const ModerationRequest = struct {
    input: []const u8,
    model: ?[]const u8 = null,
};

pub const ModerationCategories = struct {
    hate: bool = false,
    @"hate/threatening": bool = false,
    harassment: bool = false,
    @"harassment/threatening": bool = false,
    @"self-harm": bool = false,
    sexual: bool = false,
    @"sexual/minors": bool = false,
    violence: bool = false,
    @"violence/graphic": bool = false,
};

pub const ModerationResult = struct {
    flagged: bool,
    categories: ModerationCategories,
};

pub const ModerationResponse = struct {
    id: []const u8,
    model: []const u8,
    results: []const ModerationResult,
};

// ============================================================================
// Error Types
// ============================================================================

pub const ErrorResponse = struct {
    @"error": struct {
        message: []const u8,
        type: []const u8,
        param: ?[]const u8 = null,
        code: ?[]const u8 = null,
    },
};

// ============================================================================
// Helper Functions
// ============================================================================

pub fn createChatResponse(
    _: Allocator,
    id: []const u8,
    model: []const u8,
    content: []const u8,
    usage: Usage,
) ChatCompletionResponse {
    const choice = ChatCompletionChoice{
        .index = 0,
        .message = Message{
            .role = "assistant",
            .content = content,
        },
        .finish_reason = "stop",
    };

    return ChatCompletionResponse{
        .id = id,
        .object = "chat.completion",
        .created = std.time.timestamp(),
        .model = model,
        .choices = &[_]ChatCompletionChoice{choice},
        .usage = usage,
    };
}

/// Rough token estimate: ~1 token per 4 bytes (GPT-family approximation).
pub fn estimateTokens(text: []const u8) u32 {
    if (text.len == 0) return 0;
    return @max(1, @as(u32, @intCast(text.len / 4)));
}

pub fn createStreamChunk(
    id: []const u8,
    model: []const u8,
    content: ?[]const u8,
    role: ?[]const u8,
    finish_reason: ?[]const u8,
) ChatCompletionChunk {
    return ChatCompletionChunk{
        .id = id,
        .object = "chat.completion.chunk",
        .created = std.time.timestamp(),
        .model = model,
        .choices = &[_]StreamChoice{StreamChoice{
            .index = 0,
            .delta = Delta{
                .role = role,
                .content = content,
            },
            .finish_reason = finish_reason,
        }},
    };
}

pub fn createErrorResponse(
    alloc: Allocator,
    message: []const u8,
    err_type: []const u8,
) ![]const u8 {
    const resp = ErrorResponse{
        .@"error" = .{
            .message = message,
            .type = err_type,
        },
    };
    return std.json.stringifyAlloc(alloc, resp, .{});
}

// ============================================================================
// Tests
// ============================================================================

test "message creation" {
    const msg = Message{
        .role = "user",
        .content = "Hello",
    };
    try std.testing.expectEqualStrings("user", msg.role);
    try std.testing.expectEqualStrings("Hello", msg.content);
}

test "usage structure" {
    const usage = Usage{
        .prompt_tokens = 10,
        .completion_tokens = 20,
        .total_tokens = 30,
    };
    try std.testing.expectEqual(@as(u32, 30), usage.total_tokens);
}

test "tool and function types" {
    const tool = Tool{
        .type = "function",
        .function = FunctionDefinition{
            .name = "get_weather",
            .description = "Get weather for a location",
            .parameters = "{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\"}}}",
        },
    };
    try std.testing.expectEqualStrings("function", tool.type);
    try std.testing.expectEqualStrings("get_weather", tool.function.name);
}

test "chat request with extended fields" {
    const req = ChatCompletionRequest{
        .model = "llama-3.1-8b",
        .messages = &[_]Message{.{ .role = "user", .content = "Hello" }},
        .n = 2,
        .seed = 42,
        .logprobs = true,
        .top_logprobs = 5,
        .response_format = ResponseFormat{ .type = "json_object" },
    };
    try std.testing.expectEqual(@as(u32, 2), req.n.?);
    try std.testing.expectEqual(@as(i64, 42), req.seed.?);
    try std.testing.expect(req.logprobs.?);
}

test "moderation types" {
    const result = ModerationResult{
        .flagged = false,
        .categories = ModerationCategories{},
    };
    try std.testing.expect(!result.flagged);
    try std.testing.expect(!result.categories.hate);
}

test "usage with details" {
    const usage = Usage{
        .prompt_tokens = 100,
        .completion_tokens = 50,
        .total_tokens = 150,
        .prompt_tokens_details = UsageDetails{ .cached_tokens = 30 },
        .completion_tokens_details = UsageDetails{ .reasoning_tokens = 10 },
    };
    try std.testing.expectEqual(@as(u32, 30), usage.prompt_tokens_details.?.cached_tokens);
}

test "estimateTokens" {
    try std.testing.expectEqual(@as(u32, 0), estimateTokens(""));
    try std.testing.expectEqual(@as(u32, 1), estimateTokens("Hi"));
    try std.testing.expect(estimateTokens("The quick brown fox jumps over the lazy dog") > 5);
}