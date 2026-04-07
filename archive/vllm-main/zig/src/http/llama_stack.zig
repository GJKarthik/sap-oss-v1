const std = @import("std");
const Allocator = std.mem.Allocator;

/// Llama Stack request types
pub const LlamaStackRequest = struct {
    model_id: []const u8 = "",
    messages: []const LlamaMessage = &.{},
    system_prompt: []const u8 = "",
    sampling_params: SamplingParams = .{},
    stream: bool = false,
};

pub const LlamaMessage = struct {
    role: []const u8 = "",
    content: []const u8 = "",
};

pub const SamplingParams = struct {
    temperature: f32 = 0.7,
    top_p: f32 = 0.9,
    top_k: u32 = 40,
    max_tokens: u32 = 512,
    repetition_penalty: f32 = 1.0,
};

/// Llama Stack response types
pub const LlamaStackResponse = struct {
    completion_message: CompletionMessage,
    model_id: []const u8,
};

pub const CompletionMessage = struct {
    role: []const u8 = "assistant",
    content: []const u8 = "",
    stop_reason: []const u8 = "end_of_turn",
};

pub const OpenAIStyleRequest = struct {
    model: []const u8,
    temperature: f32,
    top_p: f32,
    max_tokens: u32,
    messages_count: u32,
};

/// Convert Llama Stack request to OpenAI-style request
pub fn toOpenAIRequest(req: *const LlamaStackRequest) OpenAIStyleRequest {
    return .{
        .model = req.model_id,
        .temperature = req.sampling_params.temperature,
        .top_p = req.sampling_params.top_p,
        .max_tokens = req.sampling_params.max_tokens,
        .messages_count = @intCast(req.messages.len),
    };
}

/// Convert OpenAI-style response to Llama Stack response
pub fn fromOpenAIResponse(allocator: Allocator, model_id: []const u8, content: []const u8, finish_reason: []const u8) !LlamaStackResponse {
    _ = allocator;
    const mapped_reason = mapFinishReason(finish_reason);
    return .{
        .completion_message = .{
            .role = "assistant",
            .content = content,
            .stop_reason = mapped_reason,
        },
        .model_id = model_id,
    };
}

/// Map Llama Stack stop reasons to OpenAI finish reasons
pub fn mapStopReason(reason: []const u8) []const u8 {
    if (std.mem.eql(u8, reason, "end_of_turn")) return "stop";
    if (std.mem.eql(u8, reason, "max_tokens")) return "length";
    return "stop";
}

/// Map OpenAI finish reasons to Llama Stack stop reasons
pub fn mapFinishReason(reason: []const u8) []const u8 {
    if (std.mem.eql(u8, reason, "stop")) return "end_of_turn";
    if (std.mem.eql(u8, reason, "length")) return "max_tokens";
    return "end_of_turn";
}

// Tests
const testing = std.testing;

test "toOpenAIRequest converts model_id correctly" {
    var messages: [1]LlamaMessage = .{.{ .role = "user", .content = "hello" }};
    const req = LlamaStackRequest{
        .model_id = "llama-7b",
        .messages = &messages,
        .sampling_params = .{ .temperature = 0.5, .max_tokens = 256 },
    };
    const openai_req = toOpenAIRequest(&req);
    try testing.expectEqualStrings("llama-7b", openai_req.model);
    try testing.expectEqual(@as(f32, 0.5), openai_req.temperature);
    try testing.expectEqual(@as(u32, 256), openai_req.max_tokens);
}

test "toOpenAIRequest preserves sampling parameters" {
    const req = LlamaStackRequest{
        .model_id = "test-model",
        .sampling_params = .{ .temperature = 0.8, .top_p = 0.95, .top_k = 50, .max_tokens = 1024 },
    };
    const openai_req = toOpenAIRequest(&req);
    try testing.expectEqual(@as(f32, 0.8), openai_req.temperature);
    try testing.expectEqual(@as(f32, 0.95), openai_req.top_p);
    try testing.expectEqual(@as(u32, 1024), openai_req.max_tokens);
}

test "mapStopReason converts end_of_turn to stop" {
    const mapped = mapStopReason("end_of_turn");
    try testing.expectEqualStrings("stop", mapped);
}

test "mapFinishReason converts stop to end_of_turn" {
    const mapped = mapFinishReason("stop");
    try testing.expectEqualStrings("end_of_turn", mapped);
    const mapped_length = mapFinishReason("length");
    try testing.expectEqualStrings("max_tokens", mapped_length);
}

