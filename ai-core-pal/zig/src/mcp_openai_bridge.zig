const std = @import("std");
const mcp = @import("mcp/mcp.zig");

// ============================================================================
// OpenAI API Types
// ============================================================================

pub const ChatCompletionRequest = struct {
    model: []const u8,
    messages: []const Message,
    tools: ?[]const ToolDefinition = null,
    tool_choice: ?ToolChoice = null,
};

pub const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

pub const ToolDefinition = struct {
    type: []const u8 = "function",
    function: FunctionDefinition,
};

pub const FunctionDefinition = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    parameters: ?std.json.Value = null,
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: FunctionCall,
};

pub const FunctionCall = struct {
    name: []const u8,
    arguments: []const u8, // JSON string
};

pub const ToolChoice = union(enum) {
    none,
    auto,
    function: FunctionWrapper,

    pub const FunctionWrapper = struct {
        type: []const u8 = "function",
        function: struct { name: []const u8 },
    };
};

pub const ChatCompletionResponse = struct {
    id: []const u8,
    object: []const u8 = "chat.completion",
    created: i64,
    model: []const u8,
    choices: []const Choice,
    usage: ?Usage = null,
};

pub const Choice = struct {
    index: usize,
    message: Message,
    finish_reason: []const u8,
};

pub const Usage = struct {
    prompt_tokens: usize,
    completion_tokens: usize,
    total_tokens: usize,
};

// ============================================================================
// OpenAI Bridge Handler
// ============================================================================

pub const OpenAiBridge = struct {
    allocator: std.mem.Allocator,
    tools: []const mcp.Tool,

    pub fn init(allocator: std.mem.Allocator, tools: []const mcp.Tool) OpenAiBridge {
        return .{
            .allocator = allocator,
            .tools = tools,
        };
    }

    pub fn handleRequest(self: *OpenAiBridge, request_body: []const u8) ![]const u8 {
        const req = try std.json.parseFromSlice(ChatCompletionRequest, self.allocator, request_body, .{ .ignore_unknown_fields = true });
        defer req.deinit();

        // 1. Check for tool calls in the last message
        if (req.value.messages.len > 0) {
            const last_msg = req.value.messages[req.value.messages.len - 1];
            if (std.mem.eql(u8, last_msg.role, "user")) {
                // For now, simulate tool execution if the prompt starts with "execute" or matches a tool name
                // In a real scenario, an LLM would parse this. Here we do simple keyword matching to mock the agent.
                if (last_msg.content) |content| {
                    for (self.tools) |tool| {
                        if (std.mem.indexOf(u8, content, tool.name) != null) {
                            return self.executeToolAndRespond(tool.name, "{}");
                        }
                    }
                }
            }
        }

        return self.createSimpleResponse("I am the BDC AIPrompt Bridge. I can execute PAL tools via MCP.");
    }

    fn executeToolAndRespond(self: *OpenAiBridge, tool_name: []const u8, args_json: []const u8) ![]const u8 {
        // In a real implementation, this would dispatch to the actual tool logic.
        // For the bridge prototype, we return a mock success response.
        const mock_result = try std.fmt.allocPrint(self.allocator, "Executed tool {s} with args {s}", .{ tool_name, args_json });
        defer self.allocator.free(mock_result);

        return self.createSimpleResponse(mock_result);
    }

    fn createSimpleResponse(self: *OpenAiBridge, content: []const u8) ![]const u8 {
        // Manual JSON serialization since std.json.stringify is acting up
        const ts = std.time.timestamp();
        return std.fmt.allocPrint(self.allocator,
            "{{\"id\":\"chatcmpl-mock\",\"object\":\"chat.completion\",\"created\":{d},\"model\":\"bdc-aiprompt-bridge\",\"choices\":[{{\"index\":0,\"message\":{{\"role\":\"assistant\",\"content\":\"{s}\"}},\"finish_reason\":\"stop\"}}]}}",
            .{ ts, content }
        );
    }
};
