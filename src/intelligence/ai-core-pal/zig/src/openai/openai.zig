const std = @import("std");

// ============================================================================
// OpenAI-Compatible Request/Response Types
// ============================================================================

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub const ChatRequest = struct {
    model: []const u8,
    messages: []const ChatMessage,
    temperature: ?f64 = null,
    max_tokens: ?u32 = null,
};

pub fn parseRequest(allocator: std.mem.Allocator, body: []const u8) !ChatRequest {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidRequest;

    const model = getStr(root, "model") orelse "mcppal-mesh-gateway-v1";

    // Extract last user message
    var last_user_msg: []const u8 = "";
    var messages_list: std.ArrayList(ChatMessage) = .{};
    defer messages_list.deinit(allocator);

    if (root.object.get("messages")) |msgs| {
        if (msgs == .array) {
            for (msgs.array.items) |msg| {
                if (msg == .object) {
                    const role = getStr(msg, "role") orelse "user";
                    const content = getStr(msg, "content") orelse "";
                    try messages_list.append(allocator, .{
                        .role = try allocator.dupe(u8, role),
                        .content = try allocator.dupe(u8, content),
                    });
                    if (std.mem.eql(u8, role, "user")) {
                        last_user_msg = content;
                    }
                }
            }
        }
    }

    return .{
        .model = try allocator.dupe(u8, model),
        .messages = try messages_list.toOwnedSlice(allocator),
    };
}

pub fn getLastUserMessage(req: *const ChatRequest) []const u8 {
    var i = req.messages.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, req.messages[i].role, "user")) {
            return req.messages[i].content;
        }
    }
    return "";
}

// ============================================================================
// OpenAI Chat Completion Response Builder
// ============================================================================

pub fn buildChatCompletion(
    allocator: std.mem.Allocator,
    model: []const u8,
    content: []const u8,
    tool_name: ?[]const u8,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);

    try w.writeAll("{\"id\":\"chatcmpl-mcppal-");
    // Simple timestamp-based ID
    try w.print("{d}", .{std.time.timestamp()});
    try w.writeAll("\",\"object\":\"chat.completion\",\"created\":");
    try w.print("{d}", .{std.time.timestamp()});
    try w.writeAll(",\"model\":\"");
    try w.writeAll(model);
    try w.writeAll("\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":");
    try writeJsonString(w, content);
    if (tool_name) |tn| {
        try w.writeAll(",\"tool_calls\":[{\"id\":\"call_mcppal_1\",\"type\":\"function\",\"function\":{\"name\":\"");
        try w.writeAll(tn);
        try w.writeAll("\",\"arguments\":\"{}\"}}]");
    }
    try w.writeAll("},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":0,\"total_tokens\":0}}");

    return buf.toOwnedSlice(allocator);
}

pub fn buildModelsResponse(allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);

    try w.writeAll("{\"object\":\"list\",\"data\":[");
    try w.writeAll("{\"id\":\"mcppal-mesh-gateway-v1\",\"object\":\"model\",\"created\":1700000000,\"owned_by\":\"ainuc\",\"permission\":[],\"root\":\"mcppal-mesh-gateway-v1\",\"parent\":null},");
    try w.writeAll("{\"id\":\"mcppal-pal-catalog-v1\",\"object\":\"model\",\"created\":1700000000,\"owned_by\":\"ainuc\",\"permission\":[],\"root\":\"mcppal-pal-catalog-v1\",\"parent\":null}");
    try w.writeAll("]}");

    return buf.toOwnedSlice(allocator);
}

pub fn buildErrorResponse(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);

    try w.writeAll("{\"error\":{\"message\":");
    try writeJsonString(w, message);
    try w.writeAll(",\"type\":\"invalid_request_error\",\"param\":null,\"code\":null}}");

    return buf.toOwnedSlice(allocator);
}

// ============================================================================
// Helpers
// ============================================================================

pub fn getJsonStr(val: std.json.Value, key: []const u8) ?[]const u8 {
    return getStr(val, key);
}

fn getStr(val: std.json.Value, key: []const u8) ?[]const u8 {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}
