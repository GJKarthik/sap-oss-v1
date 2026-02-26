//! MCP Input Validation Module
//!
//! Security-focused validation for MCP JSON-RPC requests.
//!
//! Validates:
//! - JSON-RPC 2.0 protocol compliance
//! - Method name format (alphanumeric, hyphens, slashes)
//! - Parameter constraints (max depth, max size)
//! - Tool name allowlist
//! - Resource URI format
//!
//! Prevents:
//! - JSON injection attacks
//! - Path traversal in resource URIs
//! - Excessive parameter depth (DoS)
//! - Oversized payloads

const std = @import("std");
const mcp = @import("mcp.zig");

/// Validation configuration
pub const ValidationConfig = struct {
    /// Maximum JSON nesting depth
    max_json_depth: usize = 32,
    /// Maximum parameter object keys
    max_params_keys: usize = 100,
    /// Maximum string value length
    max_string_length: usize = 64 * 1024, // 64KB
    /// Maximum total payload size
    max_payload_size: usize = 1024 * 1024, // 1MB
    /// Allowed tool names (null = all defined tools allowed)
    allowed_tools: ?[]const []const u8 = null,
};

/// Validation errors
pub const ValidationError = error{
    InvalidJsonRpc,
    InvalidMethod,
    InvalidParams,
    MethodNotAllowed,
    PayloadTooLarge,
    NestingTooDeep,
    TooManyKeys,
    StringTooLong,
    PathTraversal,
    InvalidUri,
    MissingRequiredField,
    InvalidIdType,
};

/// Validation result
pub const ValidationResult = struct {
    valid: bool,
    error_code: ?i32 = null,
    error_message: ?[]const u8 = null,
    
    pub fn ok() ValidationResult {
        return .{ .valid = true };
    }
    
    pub fn fail(code: i32, message: []const u8) ValidationResult {
        return .{
            .valid = false,
            .error_code = code,
            .error_message = message,
        };
    }
};

/// JSON-RPC 2.0 error codes
pub const JsonRpcErrorCode = struct {
    pub const ParseError: i32 = -32700;
    pub const InvalidRequest: i32 = -32600;
    pub const MethodNotFound: i32 = -32601;
    pub const InvalidParams: i32 = -32602;
    pub const InternalError: i32 = -32603;
    
    // Custom error codes (application-defined, < -32000)
    pub const ValidationFailed: i32 = -32001;
    pub const PayloadTooLarge: i32 = -32002;
    pub const SecurityViolation: i32 = -32003;
};

/// Validate a raw JSON-RPC request payload
pub fn validateRawPayload(payload: []const u8, config: ValidationConfig) ValidationResult {
    // Check payload size
    if (payload.len > config.max_payload_size) {
        return ValidationResult.fail(JsonRpcErrorCode.PayloadTooLarge, "Payload exceeds maximum size");
    }
    
    // Check for null bytes (security)
    if (std.mem.indexOf(u8, payload, &[_]u8{0}) != null) {
        return ValidationResult.fail(JsonRpcErrorCode.SecurityViolation, "Null bytes not allowed in payload");
    }
    
    return ValidationResult.ok();
}

/// Validate parsed JSON-RPC request structure
pub fn validateJsonRpcRequest(parsed: std.json.Value, config: ValidationConfig) ValidationResult {
    // Must be an object
    if (parsed != .object) {
        return ValidationResult.fail(JsonRpcErrorCode.InvalidRequest, "Request must be a JSON object");
    }
    
    const obj = parsed.object;
    
    // Required: jsonrpc field must be "2.0"
    if (obj.get("jsonrpc")) |jsonrpc| {
        if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
            return ValidationResult.fail(JsonRpcErrorCode.InvalidRequest, "jsonrpc must be \"2.0\"");
        }
    } else {
        return ValidationResult.fail(JsonRpcErrorCode.InvalidRequest, "Missing jsonrpc field");
    }
    
    // Required: method field
    if (obj.get("method")) |method| {
        if (method != .string) {
            return ValidationResult.fail(JsonRpcErrorCode.InvalidRequest, "method must be a string");
        }
        const method_result = validateMethodName(method.string);
        if (!method_result.valid) return method_result;
    } else {
        return ValidationResult.fail(JsonRpcErrorCode.InvalidRequest, "Missing method field");
    }
    
    // Optional: id field (must be string, number, or null)
    if (obj.get("id")) |id| {
        switch (id) {
            .string, .integer, .null => {},
            else => return ValidationResult.fail(JsonRpcErrorCode.InvalidRequest, "id must be string, number, or null"),
        }
    }
    
    // Optional: params field (validate depth and keys)
    if (obj.get("params")) |params| {
        const params_result = validateParams(params, config, 0);
        if (!params_result.valid) return params_result;
    }
    
    return ValidationResult.ok();
}

/// Validate JSON-RPC method name
pub fn validateMethodName(method: []const u8) ValidationResult {
    if (method.len == 0) {
        return ValidationResult.fail(JsonRpcErrorCode.InvalidRequest, "Method name cannot be empty");
    }
    
    if (method.len > 128) {
        return ValidationResult.fail(JsonRpcErrorCode.InvalidRequest, "Method name too long");
    }
    
    // Method name must be alphanumeric with hyphens, underscores, slashes, dots
    for (method) |c| {
        const valid = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '/' or c == '.';
        if (!valid) {
            return ValidationResult.fail(JsonRpcErrorCode.InvalidRequest, "Method name contains invalid characters");
        }
    }
    
    // Prevent path traversal in method names
    if (std.mem.indexOf(u8, method, "..") != null) {
        return ValidationResult.fail(JsonRpcErrorCode.SecurityViolation, "Path traversal not allowed in method name");
    }
    
    return ValidationResult.ok();
}

/// Validate params recursively with depth limit
fn validateParams(value: std.json.Value, config: ValidationConfig, depth: usize) ValidationResult {
    if (depth > config.max_json_depth) {
        return ValidationResult.fail(JsonRpcErrorCode.ValidationFailed, "JSON nesting too deep");
    }
    
    switch (value) {
        .object => |obj| {
            if (obj.count() > config.max_params_keys) {
                return ValidationResult.fail(JsonRpcErrorCode.ValidationFailed, "Too many object keys");
            }
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                // Validate key length
                if (entry.key_ptr.len > 256) {
                    return ValidationResult.fail(JsonRpcErrorCode.ValidationFailed, "Object key too long");
                }
                // Recursively validate value
                const result = validateParams(entry.value_ptr.*, config, depth + 1);
                if (!result.valid) return result;
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                const result = validateParams(item, config, depth + 1);
                if (!result.valid) return result;
            }
        },
        .string => |s| {
            if (s.len > config.max_string_length) {
                return ValidationResult.fail(JsonRpcErrorCode.ValidationFailed, "String value too long");
            }
        },
        else => {},
    }
    
    return ValidationResult.ok();
}

/// Validate MCP tool call
pub fn validateToolCall(tool_name: []const u8, config: ValidationConfig) ValidationResult {
    // Validate tool name format
    const method_result = validateMethodName(tool_name);
    if (!method_result.valid) return method_result;
    
    // Check against allowlist if configured
    if (config.allowed_tools) |allowed| {
        var found = false;
        for (allowed) |allowed_tool| {
            if (std.mem.eql(u8, tool_name, allowed_tool)) {
                found = true;
                break;
            }
        }
        if (!found) {
            return ValidationResult.fail(JsonRpcErrorCode.MethodNotFound, "Tool not in allowlist");
        }
    } else {
        // Check against defined tools
        const tools = mcp.getTools();
        var found = false;
        for (&tools) |tool| {
            if (std.mem.eql(u8, tool_name, tool.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            return ValidationResult.fail(JsonRpcErrorCode.MethodNotFound, "Unknown tool");
        }
    }
    
    return ValidationResult.ok();
}

/// Validate MCP resource URI
pub fn validateResourceUri(uri: []const u8) ValidationResult {
    if (uri.len == 0) {
        return ValidationResult.fail(JsonRpcErrorCode.InvalidParams, "Resource URI cannot be empty");
    }
    
    if (uri.len > 2048) {
        return ValidationResult.fail(JsonRpcErrorCode.InvalidParams, "Resource URI too long");
    }
    
    // Prevent path traversal
    if (std.mem.indexOf(u8, uri, "..") != null) {
        return ValidationResult.fail(JsonRpcErrorCode.SecurityViolation, "Path traversal not allowed in URI");
    }
    
    // Check for null bytes
    if (std.mem.indexOf(u8, uri, &[_]u8{0}) != null) {
        return ValidationResult.fail(JsonRpcErrorCode.SecurityViolation, "Null bytes not allowed in URI");
    }
    
    // URI should start with a scheme or /
    if (!std.mem.startsWith(u8, uri, "/") and
        !std.mem.startsWith(u8, uri, "pal://") and
        !std.mem.startsWith(u8, uri, "hana://") and
        !std.mem.startsWith(u8, uri, "schema://") and
        !std.mem.startsWith(u8, uri, "graph://"))
    {
        return ValidationResult.fail(JsonRpcErrorCode.InvalidParams, "Invalid URI scheme");
    }
    
    return ValidationResult.ok();
}

/// Sanitize string for safe JSON output
pub fn sanitizeForJson(allocator: std.mem.Allocator, input: []const u8, max_length: usize) ![]u8 {
    const safe_len = @min(input.len, max_length);
    var output = try allocator.alloc(u8, safe_len);
    
    for (0..safe_len) |i| {
        const c = input[i];
        // Replace control characters with space
        if (c < 0x20 and c != '\n' and c != '\r' and c != '\t') {
            output[i] = ' ';
        } else {
            output[i] = c;
        }
    }
    
    return output;
}

// ============================================================================
// Default Validation Configuration
// ============================================================================

/// Get default validation config for production use
pub fn defaultConfig() ValidationConfig {
    return .{
        .max_json_depth = 32,
        .max_params_keys = 100,
        .max_string_length = 64 * 1024,
        .max_payload_size = 1024 * 1024,
        .allowed_tools = null,
    };
}

/// Get strict validation config for high-security environments
pub fn strictConfig() ValidationConfig {
    return .{
        .max_json_depth = 16,
        .max_params_keys = 50,
        .max_string_length = 16 * 1024,
        .max_payload_size = 256 * 1024,
        .allowed_tools = null,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "validateMethodName valid" {
    try std.testing.expect(validateMethodName("initialize").valid);
    try std.testing.expect(validateMethodName("tools/call").valid);
    try std.testing.expect(validateMethodName("notifications/progress").valid);
    try std.testing.expect(validateMethodName("pal-catalog").valid);
}

test "validateMethodName invalid" {
    try std.testing.expect(!validateMethodName("").valid);
    try std.testing.expect(!validateMethodName("../etc/passwd").valid);
    try std.testing.expect(!validateMethodName("method;drop table").valid);
}

test "validateResourceUri valid" {
    try std.testing.expect(validateResourceUri("/pal/algorithms").valid);
    try std.testing.expect(validateResourceUri("pal://catalog/kmeans").valid);
    try std.testing.expect(validateResourceUri("hana://schema/SALES").valid);
}

test "validateResourceUri invalid" {
    try std.testing.expect(!validateResourceUri("").valid);
    try std.testing.expect(!validateResourceUri("../../../etc/passwd").valid);
    try std.testing.expect(!validateResourceUri("http://evil.com").valid);
}

test "validateRawPayload size" {
    const config = ValidationConfig{ .max_payload_size = 100 };
    const small = "a" ** 50;
    const large = "b" ** 200;
    
    try std.testing.expect(validateRawPayload(small, config).valid);
    try std.testing.expect(!validateRawPayload(large, config).valid);
}