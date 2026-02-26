const std = @import("std");

// ============================================================================
// MCP JSON-RPC Protocol Types
// ============================================================================

pub const JsonRpcRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?JsonRpcId = null,
    method: []const u8,
    params: ?std.json.Value = null,
};

pub const JsonRpcId = union(enum) {
    string: []const u8,
    integer: i64,

    pub fn jsonStringify(self: JsonRpcId, options: std.json.StringifyOptions, writer: anytype) !void {
        _ = options;
        switch (self) {
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .integer => |i| try writer.print("{d}", .{i}),
        }
    }
};

pub const ServerInfo = struct {
    name: []const u8 = "mcppal-mesh-gateway",
    version: []const u8 = "1.0.0",
};

pub const ServerCapabilities = struct {
    tools: ToolsCapability = .{},
    prompts: PromptsCapability = .{},
    resources: ResourcesCapability = .{},
};

pub const ToolsCapability = struct {
    listChanged: bool = false,
};

pub const PromptsCapability = struct {
    listChanged: bool = false,
};

pub const ResourcesCapability = struct {
    subscribe: bool = false,
    listChanged: bool = false,
};

pub const InitializeResult = struct {
    protocolVersion: []const u8 = "2024-11-05",
    capabilities: ServerCapabilities = .{},
    serverInfo: ServerInfo = .{},
};

// ============================================================================
// Tool Definitions
// ============================================================================

pub const ToolInputSchema = struct {
    type: []const u8 = "object",
    properties: std.json.Value = .null,
    required: ?[]const []const u8 = null,
};

pub const ToolAnnotations = struct {
    title: []const u8,
    readOnlyHint: bool = false,
    destructiveHint: bool = false,
    idempotentHint: bool = true,
    openWorldHint: bool = false,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    annotations: ToolAnnotations,
    inputSchema: ToolInputSchema,
};

pub const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,
};

pub const ToolResult = struct {
    content: []const TextContent,
    isError: bool = false,
};

// ============================================================================
// PAL MCP Tool Definitions
// ============================================================================

pub fn getTools() [13]Tool {
    return .{
        .{
            .name = "pal-catalog",
            .description = "List or search the 162 SAP HANA PAL algorithms across 13 categories. " ++
                "Filter by category, tag, use case, or search by name/description.",
            .annotations = .{
                .title = "PAL Algorithm Catalog",
                .readOnlyHint = true,
            },
            .inputSchema = .{},
        },
        .{
            .name = "pal-execute",
            .description = "Generate a HANA SQL CALL script for a PAL algorithm. " ++
                "Produces ready-to-run SQLScript with parameter tables and _SYS_AFL procedure calls. " ++
                "When a table name is provided and schema is loaded, generates schema-aware SQL with actual column names.",
            .annotations = .{
                .title = "Execute PAL Algorithm",
                .destructiveHint = true,
            },
            .inputSchema = .{},
        },
        .{
            .name = "pal-spec",
            .description = "Read the ODPS YAML specification for a PAL algorithm. " ++
                "Returns full algorithm details: parameters, enums, structs, examples, best practices.",
            .annotations = .{
                .title = "PAL Algorithm Specification",
                .readOnlyHint = true,
            },
            .inputSchema = .{},
        },
        .{
            .name = "pal-sql",
            .description = "Retrieve the SQL template for a PAL algorithm. " ++
                "Returns the SQLScript wrapper procedure including table definitions and parameter handling.",
            .annotations = .{
                .title = "PAL SQL Template",
                .readOnlyHint = true,
            },
            .inputSchema = .{},
        },
        .{
            .name = "schema-explore",
            .description = "List all tables discovered from the connected HANA database schema. " ++
                "Returns table names, column counts, and primary key information.",
            .annotations = .{
                .title = "Explore Database Schema",
                .readOnlyHint = true,
            },
            .inputSchema = .{},
        },
        .{
            .name = "describe-table",
            .description = "Describe a specific table from the HANA schema. " ++
                "Returns column names, data types, nullability, primary keys, and foreign key relationships.",
            .annotations = .{
                .title = "Describe Table",
                .readOnlyHint = true,
            },
            .inputSchema = .{},
        },
        .{
            .name = "schema-refresh",
            .description = "Re-discover the HANA database schema by re-querying SYS.TABLES, SYS.TABLE_COLUMNS, " ++
                "SYS.CONSTRAINTS, and SYS.REFERENTIAL_CONSTRAINTS. Use after schema changes.",
            .annotations = .{
                .title = "Refresh Schema",
                .idempotentHint = true,
            },
            .inputSchema = .{},
        },
        .{
            .name = "hybrid-search",
            .description = "Execute a hybrid search combining vector similarity and keyword matching with " ++
                "Reciprocal Rank Fusion (RRF). Searches PAL documentation, algorithm specs, and indexed content. " ++
                "Supports semantic queries for finding relevant algorithms, examples, and data patterns.",
            .annotations = .{
                .title = "Hybrid Search",
                .readOnlyHint = true,
                .openWorldHint = true,
            },
            .inputSchema = .{},
        },
        .{
            .name = "es-translate",
            .description = "Translate an Elasticsearch Query DSL expression to equivalent HANA SQL. " ++
                "Supports term, match, bool, range, fuzzy, KNN/vector queries, and aggregations. " ++
                "Uses Mangle Datalog rules from es_to_hana.mg for declarative translation.",
            .annotations = .{
                .title = "ES to HANA Translator",
                .readOnlyHint = true,
            },
            .inputSchema = .{},
        },
        .{
            .name = "pal-optimize",
            .description = "Get optimization recommendations for a PAL algorithm execution. " ++
                "Analyzes data characteristics (size, distribution, cardinality) and recommends: " ++
                "best algorithm variant, parameter tuning, normalization method, parallelism settings, " ++
                "and memory configuration. Uses Mangle rules from pal_optimizer.mg.",
            .annotations = .{
                .title = "PAL Optimizer",
                .readOnlyHint = true,
            },
            .inputSchema = .{},
        },
        .{
            .name = "graph-publish",
            .description = "Publish PAL execution results, HANA schema metadata, or data product definitions " ++
                "as graph nodes and relationships to the deductive database (neo4j-be-po-deductive-db). " ++
                "Enables lineage tracking, dependency analysis, and impact assessment across data products.",
            .annotations = .{
                .title = "Publish to Graph",
                .destructiveHint = true,
            },
            .inputSchema = .{},
        },
        .{
            .name = "graph-query",
            .description = "Query the deductive database graph for lineage, dependencies, impact analysis, " ++
                "and data product metadata. Uses Mangle Datalog inference (forward/backward chaining) " ++
                "for transitive dependency resolution, reachability, and quality reasoning.",
            .annotations = .{
                .title = "Query Graph",
                .readOnlyHint = true,
                .openWorldHint = true,
            },
            .inputSchema = .{},
        },
        .{
            .name = "odata-fetch",
            .description = "Fetch data from SAP OData services (S/4HANA, BW/4HANA, CDS views) to use as " ++
                "context for PAL algorithm selection and execution. Supports entity set queries with " ++
                "OData $filter, $top, $select, and $expand parameters.",
            .annotations = .{
                .title = "Fetch OData",
                .readOnlyHint = true,
                .openWorldHint = true,
            },
            .inputSchema = .{},
        },
    };
}

// ============================================================================
// MCP Resource Definitions
// ============================================================================

pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    description: []const u8,
    mimeType: []const u8 = "application/json",
};

pub const ResourceContents = struct {
    uri: []const u8,
    mimeType: []const u8 = "application/json",
    text: []const u8,
};

pub const ResourceTemplate = struct {
    uriTemplate: []const u8,
    name: []const u8,
    description: []const u8,
    mimeType: []const u8 = "application/json",
};

// ============================================================================
// JSON-RPC Response Helpers
// ============================================================================

pub fn writeJsonRpcResult(writer: anytype, id: ?JsonRpcId, result_json: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |i| {
        switch (i) {
            .string => |s| {
                try writer.writeByte('"');
                try writer.writeAll(s);
                try writer.writeByte('"');
            },
            .integer => |n| try writer.print("{d}", .{n}),
        }
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"result\":");
    try writer.writeAll(result_json);
    try writer.writeByte('}');
}

pub fn writeJsonRpcError(writer: anytype, id: ?JsonRpcId, code: i32, message: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |i| {
        switch (i) {
            .string => |s| {
                try writer.writeByte('"');
                try writer.writeAll(s);
                try writer.writeByte('"');
            },
            .integer => |n| try writer.print("{d}", .{n}),
        }
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ code, message });
}

// ============================================================================
// MCP Streaming Notifications (SSE)
// ============================================================================
//
// For long-running PAL executions, stream progress via Server-Sent Events:
//   event: notification
//   data: {"jsonrpc":"2.0","method":"notifications/progress","params":{...}}
//
// Phases for a PAL execution:
//   1. "validating"   — checking parameters and schema
//   2. "preparing"    — building SQL, allocating GPU resources
//   3. "executing"    — PAL algorithm running on HANA
//   4. "postprocess"  — formatting results, publishing to graph
//   5. "complete"     — final result ready

pub const ProgressPhase = enum {
    validating,
    preparing,
    executing,
    postprocess,
    complete,

    pub fn toString(self: ProgressPhase) []const u8 {
        return switch (self) {
            .validating => "validating",
            .preparing => "preparing",
            .executing => "executing",
            .postprocess => "postprocess",
            .complete => "complete",
        };
    }

    pub fn progress(self: ProgressPhase) u8 {
        return switch (self) {
            .validating => 10,
            .preparing => 25,
            .executing => 60,
            .postprocess => 85,
            .complete => 100,
        };
    }
};

/// Write a single SSE progress notification frame.
/// `writer` should be the raw socket/stream writer.
pub fn writeSseProgressNotification(
    writer: anytype,
    operation_id: []const u8,
    phase: ProgressPhase,
    message: []const u8,
) !void {
    try writer.writeAll("event: notification\ndata: ");
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{");
    try writer.print("\"progressToken\":\"{s}\",", .{operation_id});
    try writer.print("\"progress\":{d},\"total\":100,", .{phase.progress()});
    try writer.print("\"phase\":\"{s}\",", .{phase.toString()});
    try writer.writeAll("\"message\":");
    try writeJsonString(writer, message);
    try writer.writeAll("}}\n\n");
}

/// Write a partial result SSE frame (for incremental output).
pub fn writeSsePartialResult(
    writer: anytype,
    operation_id: []const u8,
    chunk_index: usize,
    text: []const u8,
    is_final: bool,
) !void {
    try writer.writeAll("event: notification\ndata: ");
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/partialResult\",\"params\":{");
    try writer.print("\"progressToken\":\"{s}\",", .{operation_id});
    try writer.print("\"chunkIndex\":{d},", .{chunk_index});
    try writer.print("\"isFinal\":{s},", .{if (is_final) "true" else "false"});
    try writer.writeAll("\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(writer, text);
    try writer.writeAll("}]}}\n\n");
}

/// Write the final SSE JSON-RPC result frame and close the stream.
pub fn writeSseFinalResult(
    writer: anytype,
    id: ?JsonRpcId,
    result_json: []const u8,
) !void {
    try writer.writeAll("event: result\ndata: ");
    try writeJsonRpcResult(writer, id, result_json);
    try writer.writeAll("\n\n");
}

/// Write SSE headers for an HTTP response that will stream MCP notifications.
pub fn writeSseHeaders(writer: anytype) !void {
    try writer.writeAll(
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: keep-alive\r\n" ++
        "X-Accel-Buffering: no\r\n" ++
        "\r\n"
    );
}

/// Generate a unique operation ID for tracking a long-running PAL execution.
pub fn generateOperationId(allocator: std.mem.Allocator, tool_name: []const u8) ![]const u8 {
    const ts = std.time.timestamp();
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ tool_name, ts });
}

pub fn makeTextResult(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const writer = buf.writer(allocator);
    try writer.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(writer, text);
    try writer.writeAll("}]}");
    return buf.toOwnedSlice(allocator);
}

pub fn makeErrorResult(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const writer = buf.writer(allocator);
    try writer.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(writer, message);
    try writer.writeAll("}],\"isError\":true}");
    return buf.toOwnedSlice(allocator);
}

pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    try writeJsonStringRaw(writer, s);
    try writer.writeByte('"');
}

pub fn writeJsonStringRaw(writer: anytype, s: []const u8) !void {
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
}
