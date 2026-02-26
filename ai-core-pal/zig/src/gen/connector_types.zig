// ============================================================================
// Generated Zig Types from SDK Mangle Connectors
// ============================================================================
// Auto-generated from:
//   - mangle/connectors/llm.mg
//   - mangle/connectors/object_store.mg
//   - mangle/connectors/hana.mg
//   - mangle/connectors/mcp_pal.mg
//   - mangle/connectors/integration.mg

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// LLM Types (from llm.mg)
// ============================================================================

pub const LlmGatewayConfig = struct {
    service_id: []const u8,
    endpoint: []const u8,
    default_model: []const u8,
    credential_ref: []const u8,
    timeout_ms: i64,
    max_retries: i32,
};

pub const LlmRequest = struct {
    request_id: []const u8,
    service_id: []const u8,
    model: []const u8,
    messages: []const LlmMessage,
    max_tokens: i32 = 1024,
    temperature: f64 = 0.7,
    requested_at: i64,
};

pub const LlmMessage = struct {
    role: Role,
    content: []const u8,
    pub const Role = enum { system, user, assistant };
};

// ============================================================================
// Object Store Types (from object_store.mg)
// ============================================================================

pub const ObjectStoreConfig = struct {
    service_id: []const u8,
    endpoint: []const u8,
    region: []const u8,
    bucket: []const u8,
    credential_ref: []const u8,
};

// ============================================================================
// HANA Types (from hana.mg)
// ============================================================================

pub const HanaConfig = struct {
    service_id: []const u8,
    host: []const u8,
    port: i32,
    schema: []const u8,
    credential_ref: []const u8,
};

// ============================================================================
// MCP Server Types (from mcp_pal.mg)
// ============================================================================

pub const McpServer = struct {
    server_id: []const u8,
    name: []const u8,
    version: []const u8,
    protocol_version: []const u8,
    transport: Transport,

    pub const Transport = enum { stdio, sse, websocket };
};

pub const McpServerCapability = struct {
    server_id: []const u8,
    capability: Capability,

    pub const Capability = enum { tools, resources, prompts, sampling };
};

// ============================================================================
// MCP Tool Types
// ============================================================================

pub const McpTool = struct {
    tool_id: []const u8,
    server_id: []const u8,
    name: []const u8,
    description: []const u8,
    input_schema: []const u8, // JSON Schema
};

pub const McpToolParameter = struct {
    tool_id: []const u8,
    param_name: []const u8,
    param_type: []const u8,
    required: bool,
    description: []const u8,
};

pub const McpToolCall = struct {
    call_id: []const u8,
    tool_id: []const u8,
    arguments: []const u8, // JSON
    requested_at: i64,
};

pub const McpToolResult = struct {
    call_id: []const u8,
    content: []const u8,
    is_error: bool,
    duration_ms: i64,
};

// ============================================================================
// MCP Resource Types
// ============================================================================

pub const McpResource = struct {
    resource_id: []const u8,
    server_id: []const u8,
    uri: []const u8,
    name: []const u8,
    description: []const u8,
    mime_type: []const u8,
};

pub const McpResourceTemplate = struct {
    template_id: []const u8,
    server_id: []const u8,
    uri_template: []const u8,
    name: []const u8,
    description: []const u8,
};

pub const McpResourceRead = struct {
    read_id: []const u8,
    resource_id: []const u8,
    requested_at: i64,
};

pub const McpResourceContent = struct {
    read_id: []const u8,
    content_ref: []const u8, // TOON pointer
    mime_type: []const u8,
    duration_ms: i64,
    status: Status,

    pub const Status = enum { success, @"error" };
};

// ============================================================================
// MCP Prompt Types
// ============================================================================

pub const McpPrompt = struct {
    prompt_id: []const u8,
    server_id: []const u8,
    name: []const u8,
    description: []const u8,
    arguments_schema: []const u8,
};

pub const McpPromptMessage = struct {
    message_id: []const u8,
    prompt_id: []const u8,
    role: Role,
    content_type: ContentType,
    content: []const u8,

    pub const Role = enum { user, assistant };
    pub const ContentType = enum { text, image, resource };
};

// ============================================================================
// PAL Function Types
// ============================================================================

pub const PalFunction = struct {
    function_id: []const u8,
    name: []const u8,
    category: Category,
    input_tables: []const u8, // JSON
    output_tables: []const u8, // JSON
    parameters: []const u8, // JSON

    pub const Category = enum {
        classification,
        regression,
        clustering,
        timeseries,
        association,
        text,
        neural_network,
    };
};

pub const PalExecution = struct {
    exec_id: []const u8,
    service_id: []const u8,
    function_id: []const u8,
    input_refs: []const u8, // TOON pointers
    parameters: []const u8, // JSON
    requested_at: i64,
};

pub const PalResult = struct {
    exec_id: []const u8,
    output_refs: []const u8, // TOON pointers
    model_ref: ?[]const u8, // TOON pointer to model
    metrics: []const u8, // JSON
    duration_ms: i64,
    status: Status,

    pub const Status = enum { success, @"error" };
};

// ============================================================================
// PAL-Tool Binding Types
// ============================================================================

pub const PalToolBinding = struct {
    binding_id: []const u8,
    tool_id: []const u8,
    function_id: []const u8,
    input_mapping: []const u8, // JSON
    output_mapping: []const u8, // JSON
};

// ============================================================================
// Mesh Gateway Types
// ============================================================================

pub const MeshServer = struct {
    server_id: []const u8,
    endpoint: []const u8,
    transport: McpServer.Transport,
    status: Status,
    last_heartbeat: i64,

    pub const Status = enum { connected, disconnected, @"error" };

    pub fn isHealthy(self: MeshServer, now: i64) bool {
        return self.status == .connected and (now - self.last_heartbeat) < 60000;
    }
};

pub const MeshRoute = struct {
    route_id: []const u8,
    tool_pattern: []const u8, // Glob pattern
    target_server: []const u8,
    priority: i32,
};

// ============================================================================
// Service Configuration (from integration.mg)
// ============================================================================

pub const McpPalConfig = struct {
    service_id: []const u8,
    service_name: []const u8,
    version: []const u8,
    protocol_version: []const u8,
    default_transport: McpServer.Transport,
    pal_enabled: bool,
    mesh_gateway_enabled: bool,
};

// ============================================================================
// TOON Pointer Helper
// ============================================================================

pub const ToonPointer = struct {
    prefix: []const u8,
    hash: []const u8,
    size: u64,

    pub fn format(self: ToonPointer, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "toon://{s}/{s}?size={d}", .{
            self.prefix, self.hash, self.size,
        });
    }
};

// ============================================================================
// Serialization
// ============================================================================

pub fn serializeJson(comptime T: type, value: T, allocator: Allocator) ![]u8 {
    return std.json.stringifyAlloc(allocator, value, .{});
}

pub fn deserializeJson(comptime T: type, json: []const u8, allocator: Allocator) !T {
    return std.json.parseFromSlice(T, allocator, json, .{});
}