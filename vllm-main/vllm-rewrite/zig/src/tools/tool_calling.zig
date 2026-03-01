//! Tool Calling Support
//!
//! Implements function/tool calling capabilities for LLMs.
//! Supports OpenAI-compatible tool definitions and execution.
//!
//! Features:
//! - Tool definition with JSON Schema
//! - Parallel tool calls
//! - Tool response handling
//! - Validation and retry logic
//! - Streaming tool calls

const std = @import("std");

// ==============================================
// Tool Definition
// ==============================================

pub const ToolType = enum {
    function,
    retrieval,      // Future: RAG tool
    code_interpreter, // Future: code execution
};

pub const Tool = struct {
    tool_type: ToolType,
    function: FunctionDefinition,
};

pub const FunctionDefinition = struct {
    name: []const u8,
    description: ?[]const u8,
    parameters: JsonSchema,
    strict: bool,  // Enable strict JSON schema validation
    
    pub fn init(name: []const u8) FunctionDefinition {
        return .{
            .name = name,
            .description = null,
            .parameters = JsonSchema.init(),
            .strict = false,
        };
    }
    
    pub fn withDescription(self: *FunctionDefinition, desc: []const u8) *FunctionDefinition {
        self.description = desc;
        return self;
    }
    
    pub fn setStrict(self: *FunctionDefinition, strict: bool) *FunctionDefinition {
        self.strict = strict;
        return self;
    }
};

// ==============================================
// JSON Schema for Parameters
// ==============================================

pub const JsonSchemaType = enum {
    string,
    number,
    integer,
    boolean,
    array,
    object,
    null_type,
};

pub const JsonSchema = struct {
    schema_type: JsonSchemaType,
    properties: std.StringHashMap(JsonSchema),
    required: std.ArrayList([]const u8),
    items: ?*JsonSchema,        // For arrays
    enum_values: ?[]const []const u8,
    description: ?[]const u8,
    default: ?[]const u8,
    additional_properties: bool,
    
    allocator: std.mem.Allocator,
    
    pub fn init() JsonSchema {
        return initWithAllocator(std.heap.page_allocator);
    }
    
    pub fn initWithAllocator(allocator: std.mem.Allocator) JsonSchema {
        return .{
            .schema_type = .object,
            .properties = std.StringHashMap(JsonSchema).init(allocator),
            .required = std.ArrayList([]const u8).init(allocator),
            .items = null,
            .enum_values = null,
            .description = null,
            .default = null,
            .additional_properties = false,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *JsonSchema) void {
        self.properties.deinit();
        self.required.deinit();
        if (self.items) |items| {
            items.deinit();
            self.allocator.destroy(items);
        }
    }
    
    pub fn addProperty(self: *JsonSchema, name: []const u8, prop: JsonSchema) !void {
        try self.properties.put(name, prop);
    }
    
    pub fn addRequired(self: *JsonSchema, name: []const u8) !void {
        try self.required.append(name);
    }
    
    pub fn toJson(self: *const JsonSchema, allocator: std.mem.Allocator) ![]const u8 {
        var list = std.ArrayList(u8).init(allocator);
        var writer = list.writer();
        
        try writer.writeAll("{");
        try writer.print("\"type\":\"{s}\"", .{@tagName(self.schema_type)});
        
        if (self.properties.count() > 0) {
            try writer.writeAll(",\"properties\":{");
            var first = true;
            var iter = self.properties.iterator();
            while (iter.next()) |entry| {
                if (!first) try writer.writeAll(",");
                first = false;
                try writer.print("\"{s}\":", .{entry.key_ptr.*});
                const prop_json = try entry.value_ptr.toJson(allocator);
                defer allocator.free(prop_json);
                try writer.writeAll(prop_json);
            }
            try writer.writeAll("}");
        }
        
        if (self.required.items.len > 0) {
            try writer.writeAll(",\"required\":[");
            for (self.required.items, 0..) |req, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("\"{s}\"", .{req});
            }
            try writer.writeAll("]");
        }
        
        if (self.description) |desc| {
            try writer.print(",\"description\":\"{s}\"", .{desc});
        }
        
        if (!self.additional_properties) {
            try writer.writeAll(",\"additionalProperties\":false");
        }
        
        try writer.writeAll("}");
        
        return list.toOwnedSlice();
    }
};

// ==============================================
// Tool Choice
// ==============================================

pub const ToolChoiceType = enum {
    none,       // Model won't call any tools
    auto,       // Model decides
    required,   // Model must call at least one tool
    specific,   // Must call specific tool
};

pub const ToolChoice = union(enum) {
    none: void,
    auto: void,
    required: void,
    specific: struct {
        tool_type: ToolType,
        function_name: []const u8,
    },
    
    pub fn fromString(s: []const u8) ToolChoice {
        if (std.mem.eql(u8, s, "none")) return .{ .none = {} };
        if (std.mem.eql(u8, s, "auto")) return .{ .auto = {} };
        if (std.mem.eql(u8, s, "required")) return .{ .required = {} };
        return .{ .auto = {} };
    }
};

// ==============================================
// Tool Call (Output from Model)
// ==============================================

pub const ToolCall = struct {
    id: []const u8,           // Unique identifier
    tool_type: ToolType,
    function: FunctionCall,
    index: ?usize,            // For parallel calls
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, arguments: []const u8) !ToolCall {
        return .{
            .id = try generateToolCallId(allocator),
            .tool_type = .function,
            .function = .{
                .name = name,
                .arguments = arguments,
            },
            .index = null,
        };
    }
};

pub const FunctionCall = struct {
    name: []const u8,
    arguments: []const u8,  // JSON string
};

fn generateToolCallId(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [32]u8 = undefined;
    const id_part = std.crypto.random.int(u64);
    const len = std.fmt.formatIntBuf(&buf, id_part, 16, .lower, .{});
    
    var result = try allocator.alloc(u8, 9 + len);
    @memcpy(result[0..9], "call_");
    @memcpy(result[9..], buf[0..len]);
    return result;
}

// ==============================================
// Tool Response (User provides result)
// ==============================================

pub const ToolResponse = struct {
    tool_call_id: []const u8,
    content: []const u8,  // Result of tool execution
    is_error: bool,
    error_message: ?[]const u8,
    
    pub fn success(tool_call_id: []const u8, content: []const u8) ToolResponse {
        return .{
            .tool_call_id = tool_call_id,
            .content = content,
            .is_error = false,
            .error_message = null,
        };
    }
    
    pub fn err(tool_call_id: []const u8, message: []const u8) ToolResponse {
        return .{
            .tool_call_id = tool_call_id,
            .content = "",
            .is_error = true,
            .error_message = message,
        };
    }
};

// ==============================================
// Tool Call Parser
// ==============================================

pub const ToolCallParser = struct {
    allocator: std.mem.Allocator,
    tools: []const Tool,
    strict_mode: bool,
    
    // Streaming state
    current_call: ?ToolCall,
    argument_buffer: std.ArrayList(u8),
    
    pub fn init(allocator: std.mem.Allocator, tools: []const Tool) ToolCallParser {
        return .{
            .allocator = allocator,
            .tools = tools,
            .strict_mode = false,
            .current_call = null,
            .argument_buffer = std.ArrayList(u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *ToolCallParser) void {
        self.argument_buffer.deinit();
    }
    
    /// Parse tool calls from model output
    pub fn parseFromOutput(self: *ToolCallParser, output: []const u8) ![]ToolCall {
        var calls = std.ArrayList(ToolCall).init(self.allocator);
        
        // Look for JSON tool call patterns
        // Format varies by model:
        // - OpenAI: {"name": "func", "arguments": {...}}
        // - Claude: <function_calls><invoke name="func">...</invoke></function_calls>
        // - Llama: <tool_call>{"name": "func", "parameters": {...}}</tool_call>
        
        // Try to find JSON-formatted tool calls
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, output, start, "{\"name\":")) |pos| {
            if (self.tryParseJsonToolCall(output[pos..])) |call| {
                try calls.append(call);
            }
            start = pos + 1;
        }
        
        return calls.toOwnedSlice();
    }
    
    fn tryParseJsonToolCall(self: *ToolCallParser, json: []const u8) ?ToolCall {
        // Simple JSON parsing for tool calls
        // In production, would use proper JSON parser
        
        // Find function name
        const name_start = std.mem.indexOf(u8, json, "\"name\":") orelse return null;
        const name_quote_start = std.mem.indexOfPos(u8, json, name_start + 7, "\"") orelse return null;
        const name_quote_end = std.mem.indexOfPos(u8, json, name_quote_start + 1, "\"") orelse return null;
        const name = json[name_quote_start + 1 .. name_quote_end];
        
        // Validate against available tools
        var valid = false;
        for (self.tools) |tool| {
            if (std.mem.eql(u8, tool.function.name, name)) {
                valid = true;
                break;
            }
        }
        if (!valid and self.strict_mode) return null;
        
        // Find arguments
        const args_start = std.mem.indexOf(u8, json, "\"arguments\":") orelse
            std.mem.indexOf(u8, json, "\"parameters\":");
        
        if (args_start) |start| {
            // Find the opening brace after "arguments":
            const brace_start = std.mem.indexOfPos(u8, json, start, "{") orelse return null;
            
            // Find matching closing brace
            var depth: i32 = 0;
            var brace_end: usize = brace_start;
            for (json[brace_start..], brace_start..) |c, i| {
                if (c == '{') depth += 1;
                if (c == '}') depth -= 1;
                if (depth == 0) {
                    brace_end = i;
                    break;
                }
            }
            
            const arguments = json[brace_start .. brace_end + 1];
            
            return ToolCall.init(self.allocator, name, arguments) catch null;
        }
        
        return null;
    }
    
    /// Streaming: process incremental output
    pub fn processStreamingChunk(self: *ToolCallParser, chunk: []const u8) !?ToolCall {
        try self.argument_buffer.appendSlice(chunk);
        
        // Check if we have a complete tool call
        const content = self.argument_buffer.items;
        
        // Look for complete JSON object
        if (std.mem.indexOf(u8, content, "\"name\":")) |_| {
            // Check for balanced braces
            var depth: i32 = 0;
            var has_content = false;
            for (content) |c| {
                if (c == '{') {
                    depth += 1;
                    has_content = true;
                }
                if (c == '}') depth -= 1;
            }
            
            if (has_content and depth == 0) {
                // Complete tool call
                const calls = try self.parseFromOutput(content);
                if (calls.len > 0) {
                    self.argument_buffer.clearRetainingCapacity();
                    return calls[0];
                }
            }
        }
        
        return null;
    }
};

// ==============================================
// Tool Validator
// ==============================================

pub const ToolValidator = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ToolValidator {
        return .{ .allocator = allocator };
    }
    
    /// Validate arguments against schema
    pub fn validateArguments(
        self: *ToolValidator,
        tool: *const Tool,
        arguments: []const u8,
    ) ValidationResult {
        _ = self;
        
        // Parse arguments as JSON
        // Validate each required field
        // Check types match schema
        
        const schema = &tool.function.parameters;
        
        // Check required fields
        for (schema.required.items) |req| {
            const key_pattern = std.fmt.allocPrint(self.allocator, "\"{s}\":", .{req}) catch continue;
            defer self.allocator.free(key_pattern);
            
            if (std.mem.indexOf(u8, arguments, key_pattern) == null) {
                return ValidationResult{
                    .valid = false,
                    .error_message = "Missing required field",
                    .missing_fields = &[_][]const u8{req},
                };
            }
        }
        
        return ValidationResult{ .valid = true, .error_message = null, .missing_fields = null };
    }
};

pub const ValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    missing_fields: ?[]const []const u8,
};

// ==============================================
// Tool Executor
// ==============================================

pub const ToolExecutor = struct {
    allocator: std.mem.Allocator,
    handlers: std.StringHashMap(ToolHandler),
    timeout_ms: u64,
    max_retries: u32,
    
    pub const ToolHandler = *const fn (arguments: []const u8) anyerror![]const u8;
    
    pub fn init(allocator: std.mem.Allocator) ToolExecutor {
        return .{
            .allocator = allocator,
            .handlers = std.StringHashMap(ToolHandler).init(allocator),
            .timeout_ms = 30000,
            .max_retries = 3,
        };
    }
    
    pub fn deinit(self: *ToolExecutor) void {
        self.handlers.deinit();
    }
    
    pub fn registerHandler(self: *ToolExecutor, name: []const u8, handler: ToolHandler) !void {
        try self.handlers.put(name, handler);
    }
    
    pub fn execute(self: *ToolExecutor, call: *const ToolCall) !ToolResponse {
        const handler = self.handlers.get(call.function.name) orelse {
            return ToolResponse.err(call.id, "Unknown function");
        };
        
        var retries: u32 = 0;
        while (retries < self.max_retries) : (retries += 1) {
            const result = handler(call.function.arguments) catch |e| {
                if (retries + 1 < self.max_retries) continue;
                return ToolResponse.err(call.id, @errorName(e));
            };
            
            return ToolResponse.success(call.id, result);
        }
        
        return ToolResponse.err(call.id, "Max retries exceeded");
    }
    
    pub fn executeParallel(self: *ToolExecutor, calls: []const ToolCall) ![]ToolResponse {
        var responses = try self.allocator.alloc(ToolResponse, calls.len);
        
        // In real implementation, would use thread pool
        for (calls, 0..) |call, i| {
            responses[i] = try self.execute(&call);
        }
        
        return responses;
    }
};

// ==============================================
// Tool Call Manager
// ==============================================

pub const ToolCallManager = struct {
    allocator: std.mem.Allocator,
    tools: std.ArrayList(Tool),
    parser: ToolCallParser,
    validator: ToolValidator,
    executor: ToolExecutor,
    
    // Configuration
    parallel_tool_calls: bool,
    max_tool_calls_per_turn: usize,
    auto_execute: bool,
    
    pub fn init(allocator: std.mem.Allocator) ToolCallManager {
        var manager = ToolCallManager{
            .allocator = allocator,
            .tools = std.ArrayList(Tool).init(allocator),
            .parser = undefined,
            .validator = ToolValidator.init(allocator),
            .executor = ToolExecutor.init(allocator),
            .parallel_tool_calls = true,
            .max_tool_calls_per_turn = 10,
            .auto_execute = false,
        };
        manager.parser = ToolCallParser.init(allocator, &[_]Tool{});
        return manager;
    }
    
    pub fn deinit(self: *ToolCallManager) void {
        self.tools.deinit();
        self.parser.deinit();
        self.executor.deinit();
    }
    
    pub fn addTool(self: *ToolCallManager, tool: Tool) !void {
        try self.tools.append(tool);
        // Update parser with new tools list
        self.parser.tools = self.tools.items;
    }
    
    pub fn processModelOutput(self: *ToolCallManager, output: []const u8) !ProcessResult {
        // Parse tool calls from output
        const calls = try self.parser.parseFromOutput(output);
        
        if (calls.len == 0) {
            return ProcessResult{
                .has_tool_calls = false,
                .tool_calls = &[_]ToolCall{},
                .responses = null,
            };
        }
        
        // Limit number of tool calls
        const limited_calls = if (calls.len > self.max_tool_calls_per_turn)
            calls[0..self.max_tool_calls_per_turn]
        else
            calls;
        
        // Validate each call
        for (limited_calls) |*call| {
            for (self.tools.items) |*tool| {
                if (std.mem.eql(u8, tool.function.name, call.function.name)) {
                    const validation = self.validator.validateArguments(tool, call.function.arguments);
                    if (!validation.valid) {
                        // Could return error or log warning
                    }
                    break;
                }
            }
        }
        
        // Auto-execute if enabled
        var responses: ?[]ToolResponse = null;
        if (self.auto_execute) {
            if (self.parallel_tool_calls) {
                responses = try self.executor.executeParallel(limited_calls);
            } else {
                var resp_list = try self.allocator.alloc(ToolResponse, limited_calls.len);
                for (limited_calls, 0..) |*call, i| {
                    resp_list[i] = try self.executor.execute(call);
                }
                responses = resp_list;
            }
        }
        
        return ProcessResult{
            .has_tool_calls = true,
            .tool_calls = limited_calls,
            .responses = responses,
        };
    }
};

pub const ProcessResult = struct {
    has_tool_calls: bool,
    tool_calls: []const ToolCall,
    responses: ?[]ToolResponse,
};

// ==============================================
// OpenAI-Compatible Serialization
// ==============================================

pub const ToolSerializer = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ToolSerializer {
        return .{ .allocator = allocator };
    }
    
    /// Serialize tools for API request
    pub fn serializeTools(self: *ToolSerializer, tools: []const Tool) ![]const u8 {
        var list = std.ArrayList(u8).init(self.allocator);
        var writer = list.writer();
        
        try writer.writeAll("[");
        for (tools, 0..) |tool, i| {
            if (i > 0) try writer.writeAll(",");
            try self.serializeTool(&tool, &writer);
        }
        try writer.writeAll("]");
        
        return list.toOwnedSlice();
    }
    
    fn serializeTool(self: *ToolSerializer, tool: *const Tool, writer: anytype) !void {
        try writer.writeAll("{");
        try writer.print("\"type\":\"{s}\"", .{@tagName(tool.tool_type)});
        
        if (tool.tool_type == .function) {
            try writer.writeAll(",\"function\":{");
            try writer.print("\"name\":\"{s}\"", .{tool.function.name});
            
            if (tool.function.description) |desc| {
                try writer.print(",\"description\":\"{s}\"", .{desc});
            }
            
            try writer.writeAll(",\"parameters\":");
            const params_json = try tool.function.parameters.toJson(self.allocator);
            defer self.allocator.free(params_json);
            try writer.writeAll(params_json);
            
            if (tool.function.strict) {
                try writer.writeAll(",\"strict\":true");
            }
            
            try writer.writeAll("}");
        }
        
        try writer.writeAll("}");
    }
    
    /// Serialize tool calls for API response
    pub fn serializeToolCalls(self: *ToolSerializer, calls: []const ToolCall) ![]const u8 {
        var list = std.ArrayList(u8).init(self.allocator);
        var writer = list.writer();
        
        try writer.writeAll("[");
        for (calls, 0..) |call, i| {
            if (i > 0) try writer.writeAll(",");
            try self.serializeToolCall(&call, &writer);
        }
        try writer.writeAll("]");
        
        return list.toOwnedSlice();
    }
    
    fn serializeToolCall(self: *ToolSerializer, call: *const ToolCall, writer: anytype) !void {
        _ = self;
        try writer.writeAll("{");
        try writer.print("\"id\":\"{s}\"", .{call.id});
        try writer.print(",\"type\":\"{s}\"", .{@tagName(call.tool_type)});
        try writer.writeAll(",\"function\":{");
        try writer.print("\"name\":\"{s}\"", .{call.function.name});
        try writer.print(",\"arguments\":{s}", .{call.function.arguments});
        try writer.writeAll("}");
        if (call.index) |idx| {
            try writer.print(",\"index\":{d}", .{idx});
        }
        try writer.writeAll("}");
    }
};

// ==============================================
// Tests
// ==============================================

test "JsonSchema basic" {
    const allocator = std.testing.allocator;
    var schema = JsonSchema.initWithAllocator(allocator);
    defer schema.deinit();
    
    var prop = JsonSchema.initWithAllocator(allocator);
    prop.schema_type = .string;
    prop.description = "The city name";
    
    try schema.addProperty("city", prop);
    try schema.addRequired("city");
    
    const json = try schema.toJson(allocator);
    defer allocator.free(json);
    
    try std.testing.expect(std.mem.indexOf(u8, json, "\"city\"") != null);
}

test "ToolChoice parsing" {
    const choice = ToolChoice.fromString("auto");
    try std.testing.expect(choice == .auto);
}

test "ToolValidator required fields" {
    const allocator = std.testing.allocator;
    var validator = ToolValidator.init(allocator);
    
    var schema = JsonSchema.initWithAllocator(allocator);
    defer schema.deinit();
    try schema.addRequired("city");
    
    const tool = Tool{
        .tool_type = .function,
        .function = .{
            .name = "get_weather",
            .description = "Get weather for city",
            .parameters = schema,
            .strict = false,
        },
    };
    
    const result = validator.validateArguments(&tool, "{\"city\":\"NYC\"}");
    try std.testing.expect(result.valid);
}