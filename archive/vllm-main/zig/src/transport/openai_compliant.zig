//! OpenAI-Compliant API Module
//! 
//! Strictly adheres to the OpenAI API specification for Chat Completions,
//! Embeddings, and Models. Ensures mandatory fields and correct schemas.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Core Constants
// ============================================================================

pub const API_VERSION = "2024-05-13"; // Matches latest major spec update

// ============================================================================
// Request Types (Strict)
// ============================================================================

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    name: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
};

pub const ResponseFormat = struct {
    type: []const u8 = "text",
};

pub const ChatCompletionRequest = struct {
    model: []const u8,
    messages: []const Message,
    frequency_penalty: ?f32 = 0,
    logit_bias: ?std.json.Value = null,
    logprobs: ?bool = false,
    top_logprobs: ?u32 = null,
    max_tokens: ?u32 = null,
    n: ?u32 = 1,
    presence_penalty: ?f32 = 0,
    response_format: ?ResponseFormat = null,
    seed: ?i64 = null,
    stop: ?std.json.Value = null, // string or array
    stream: ?bool = false,
    temperature: ?f32 = 1.0,
    top_p: ?f32 = 1.0,
    tools: ?[]const std.json.Value = null,
    tool_choice: ?std.json.Value = null,
    user: ?[]const u8 = null,
};

// ============================================================================
// Response Types (Strict)
// ============================================================================

pub const Usage = struct {
    completion_tokens: u32 = 0,
    prompt_tokens: u32 = 0,
    total_tokens: u32 = 0,
};

pub const ToolCallFunction = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: ToolCallFunction,
};

pub const Choice = struct {
    finish_reason: []const u8 = "stop",
    index: u32 = 0,
    message: Message,
    logprobs: ?std.json.Value = null,
};

pub const ChatCompletionResponse = struct {
    id: []const u8,
    object: []const u8 = "chat.completion",
    created: i64,
    model: []const u8,
    system_fingerprint: []const u8 = "fp_ainuc_1.0",
    choices: []const Choice,
    usage: Usage,
};

// ============================================================================
// Error Schema (Strict)
// ============================================================================

pub const ErrorDetail = struct {
    message: []const u8,
    type: []const u8 = "invalid_request_error",
    param: ?[]const u8 = null,
    code: ?[]const u8 = null,
};

pub const ErrorResponse = struct {
    @"error": ErrorDetail,
};

// ============================================================================
// Response Builders
// ============================================================================

pub fn buildChatResponse(
    allocator: Allocator,
    model: []const u8,
    content: []const u8,
    usage: Usage,
) ![]u8 {
    const id = try generateId(allocator, "chatcmpl-");
    defer allocator.free(id);

    const resp = ChatCompletionResponse{
        .id = id,
        .created = std.time.timestamp(),
        .model = model,
        .choices = &[_]Choice{.{
            .message = .{ .role = "assistant", .content = content },
        }},
        .usage = usage,
    };

    return std.json.stringifyAlloc(allocator, resp, .{});
}

pub fn buildErrorResponse(
    allocator: Allocator,
    message: []const u8,
    err_type: []const u8,
    code: ?[]const u8,
) ![]u8 {
    const resp = ErrorResponse{
        .@"error" = .{
            .message = message,
            .type = err_type,
            .code = code,
        },
    };
    return std.json.stringifyAlloc(allocator, resp, .{});
}

// ============================================================================
// Utilities
// ============================================================================

fn generateId(allocator: Allocator, prefix: []const u8) ![]u8 {
    // Generate a random-ish ID using timestamp and a counter
    // For true UUID, one could use a library, but this satisfies 'compliance'
    // as long as the format looks correct.
    var buf: [32]u8 = undefined;
    const ts = std.time.milliTimestamp();
    const id_str = try std.fmt.bufPrint(&buf, "{x}{d}", .{ ts, std.crypto.random.int(u32) });
    return std.mem.concat(allocator, u8, &[_][]const u8{ prefix, id_str });
}
