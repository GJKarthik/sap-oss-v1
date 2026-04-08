//! Mangle Client for Zig
//!
//! This module connects to the Mangle deductive database to query
//! tensor types, GGUF format specs, and model architectures.
//!
//! The Mangle .mg files define the specifications declaratively,
//! and this client queries them at runtime or build time.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Mangle value types
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool_: bool,
    list: []const Value,

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .int => |i| i,
            else => null,
        };
    }

    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .float => |f| f,
            else => null,
        };
    }
};

/// A fact/tuple from a Mangle query result
pub const Fact = struct {
    predicate: []const u8,
    args: []const Value,
};

/// Mangle client configuration
pub const Config = struct {
    /// URL of the Mangle server (if using remote)
    server_url: ?[]const u8 = null,
    /// Path to local .mg files
    local_path: ?[]const u8 = null,
    /// Use embedded facts (compile-time)
    use_embedded: bool = true,
};

/// Mangle client for querying specifications
pub const Client = struct {
    allocator: Allocator,
    config: Config,

    const Self = @This();

    pub fn init(allocator: Allocator, config: Config) Self {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Query a predicate and return matching facts
    pub fn query(self: *Self, predicate: []const u8) ![]const Fact {
        if (self.config.use_embedded) {
            return self.queryEmbedded(predicate);
        } else if (self.config.server_url) |_| {
            return self.queryRemote(predicate);
        } else {
            return self.queryLocal(predicate);
        }
    }

    /// Query embedded facts (compile-time generated)
    fn queryEmbedded(self: *Self, predicate: []const u8) ![]const Fact {
        _ = self;
        // Use compile-time generated lookup tables
        if (std.mem.eql(u8, predicate, "dtype")) {
            return &embedded_dtypes;
        } else if (std.mem.eql(u8, predicate, "arch")) {
            return &embedded_archs;
        } else if (std.mem.eql(u8, predicate, "model_config")) {
            return &embedded_model_configs;
        }
        return &.{};
    }

    /// Query remote Mangle server via HTTP
    fn queryRemote(self: *Self, predicate: []const u8) ![]const Fact {
        const server_url = self.config.server_url orelse return error.NoServerConfigured;
        
        // Build query URL: {server_url}/api/query?predicate={predicate}
        var url_buf: [2048]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/api/query?predicate={s}", .{
            server_url, predicate,
        }) catch return error.UrlTooLong;
        
        // Use std.http.Client for HTTP GET request
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        
        // Create buffer for response body
        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();
        
        // Perform the HTTP GET request
        const result = client.fetch(.{
            .location = .{ .uri = uri },
            .response_storage = .{ .dynamic = &response_body },
            .max_redirects = 3,
        }) catch |err| {
            std.log.warn("Mangle HTTP request failed: {}", .{err});
            return error.HttpRequestFailed;
        };
        
        if (result.status != .ok) {
            std.log.warn("Mangle server returned status: {}", .{result.status});
            return error.HttpRequestFailed;
        }
        
        // Parse JSON response into facts
        // Expected format: { "results": [{"predicate": "...", "args": [...]}] }
        const json_slice = response_body.items;
        const parsed = std.json.parseFromSlice(
            struct { results: []const JsonFact },
            self.allocator,
            json_slice,
            .{},
        ) catch return error.InvalidJsonResponse;
        defer parsed.deinit();
        
        // Convert JSON facts to our Fact type
        var facts = std.ArrayList(Fact).init(self.allocator);
        errdefer facts.deinit();
        
        for (parsed.value.results) |json_fact| {
            var args = std.ArrayList(Value).init(self.allocator);
            errdefer args.deinit();
            
            for (json_fact.args) |arg| {
                const value: Value = switch (arg) {
                    .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
                    .integer => |i| .{ .int = i },
                    .float => |f| .{ .float = f },
                    .bool => |b| .{ .bool_ = b },
                    else => continue,
                };
                try args.append(value);
            }
            
            try facts.append(.{
                .predicate = try self.allocator.dupe(u8, json_fact.predicate),
                .args = try args.toOwnedSlice(),
            });
        }
        
        return try facts.toOwnedSlice();
    }

    /// Query local .mg files (basic parser for simple facts)
    fn queryLocal(self: *Self, predicate: []const u8) ![]const Fact {
        const local_path = self.config.local_path orelse return error.NoLocalPathConfigured;
        
        // Try to open the .mg file for this predicate
        var path_buf: [1024]u8 = undefined;
        const mg_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.mg", .{
            local_path, predicate,
        }) catch return error.PathTooLong;
        
        const file = std.fs.cwd().openFile(mg_path, .{}) catch |err| {
            // If specific file doesn't exist, try default rules.mg
            if (err == error.FileNotFound) {
                const rules_path = std.fmt.bufPrint(&path_buf, "{s}/rules.mg", .{local_path}) catch return error.PathTooLong;
                return self.parseMangleFile(rules_path, predicate) catch return &.{};
            }
            return error.FileOpenFailed;
        };
        defer file.close();
        
        return self.parseMangleFileFromHandle(file, predicate);
    }
    
    /// Parse a Mangle file and extract facts matching the predicate
    fn parseMangleFile(self: *Self, path: []const u8, predicate: []const u8) ![]const Fact {
        const file = std.fs.cwd().openFile(path, .{}) catch return error.FileOpenFailed;
        defer file.close();
        return self.parseMangleFileFromHandle(file, predicate);
    }
    
    /// Parse Mangle file contents from a file handle
    fn parseMangleFileFromHandle(self: *Self, file: std.fs.File, predicate: []const u8) ![]const Fact {
        var facts = std.ArrayList(Fact).init(self.allocator);
        errdefer facts.deinit();
        
        // Read file line by line
        var reader = file.reader();
        var line_buf: [4096]u8 = undefined;
        
        while (reader.readUntilDelimiterOrEof(&line_buf, '\n')) |maybe_line| {
            const line = maybe_line orelse break;
            
            // Skip comments and empty lines
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '/') continue;
            
            // Simple parser: look for "predicate(arg1, arg2, ...)."
            // Find predicate name
            if (std.mem.indexOf(u8, trimmed, "(")) |paren_pos| {
                const pred_name = trimmed[0..paren_pos];
                
                // Check if this matches our target predicate
                if (!std.mem.eql(u8, pred_name, predicate)) continue;
                
                // Extract arguments between ( and ).
                if (std.mem.indexOf(u8, trimmed[paren_pos..], ")")) |close_pos| {
                    const args_str = trimmed[paren_pos + 1 .. paren_pos + close_pos];
                    
                    // Parse arguments (simple string splitting)
                    var args = std.ArrayList(Value).init(self.allocator);
                    errdefer args.deinit();
                    
                    var it = std.mem.splitScalar(u8, args_str, ',');
                    while (it.next()) |arg| {
                        const arg_trimmed = std.mem.trim(u8, arg, " \t\"'");
                        if (arg_trimmed.len > 0) {
                            // Try to parse as number first
                            if (std.fmt.parseInt(i64, arg_trimmed, 10)) |int_val| {
                                try args.append(.{ .int = int_val });
                            } else |_| {
                                if (std.fmt.parseFloat(f64, arg_trimmed)) |float_val| {
                                    try args.append(.{ .float = float_val });
                                } else |_| {
                                    try args.append(.{ .string = try self.allocator.dupe(u8, arg_trimmed) });
                                }
                            }
                        }
                    }
                    
                    try facts.append(.{
                        .predicate = try self.allocator.dupe(u8, pred_name),
                        .args = try args.toOwnedSlice(),
                    });
                }
            }
        } else |err| {
            std.log.warn("Error reading mangle file: {}", .{err});
        }
        
        return try facts.toOwnedSlice();
    }

    // ========================================================================
    // Convenience query methods
    // ========================================================================

    /// Get all data types
    pub fn getDataTypes(self: *Self) ![]const DataTypeInfo {
        _ = self;
        return &embedded_dtype_info;
    }

    /// Get data type by name
    pub fn getDataType(self: *Self, name: []const u8) ?DataTypeInfo {
        _ = self;
        for (embedded_dtype_info) |info| {
            if (std.mem.eql(u8, info.name, name)) {
                return info;
            }
        }
        return null;
    }

    /// Get all architectures
    pub fn getArchitectures(self: *Self) ![]const ArchInfo {
        _ = self;
        return &embedded_arch_info;
    }

    /// Get model config by name
    pub fn getModelConfig(self: *Self, name: []const u8) ?ModelConfigInfo {
        _ = self;
        for (embedded_model_config_info) |info| {
            if (std.mem.eql(u8, info.name, name)) {
                return info;
            }
        }
        return null;
    }

    /// Get all tensor patterns for an architecture
    pub fn getTensorPatterns(self: *Self, arch: []const u8) ![]const TensorPatternInfo {
        _ = self;
        _ = arch;
        // In a real implementation, we would filter by architecture
        // For now, return all patterns
        return &embedded_tensor_patterns;
    }
};

// ============================================================================
// Embedded data structures (generated from .mg files)
// ============================================================================

pub const DataTypeInfo = struct {
    name: []const u8,
    enum_value: u32,
    block_size: usize,
    block_elements: usize,
};

pub const ArchInfo = struct {
    name: []const u8,
    description: []const u8,
    attention_type: []const u8,
    norm_type: []const u8,
    activation: []const u8,
    has_bias: bool,
};

pub const ModelConfigInfo = struct {
    name: []const u8,
    arch: []const u8,
    n_layers: u32,
    n_heads: u32,
    n_kv_heads: u32,
    dim: u32,
    ff_dim: u32,
    vocab_size: u32,
    context_length: u32,
};

pub const TensorPatternInfo = struct {
    arch: []const u8,
    pattern: []const u8,
    description: []const u8,
};

// ============================================================================
// Embedded facts (from tensor_types.mg)
// ============================================================================

const embedded_dtype_info = [_]DataTypeInfo{
    .{ .name = "F32", .enum_value = 0, .block_size = 4, .block_elements = 1 },
    .{ .name = "F16", .enum_value = 1, .block_size = 2, .block_elements = 1 },
    .{ .name = "Q4_0", .enum_value = 2, .block_size = 18, .block_elements = 32 },
    .{ .name = "Q4_1", .enum_value = 3, .block_size = 20, .block_elements = 32 },
    .{ .name = "Q5_0", .enum_value = 6, .block_size = 22, .block_elements = 32 },
    .{ .name = "Q5_1", .enum_value = 7, .block_size = 24, .block_elements = 32 },
    .{ .name = "Q8_0", .enum_value = 8, .block_size = 34, .block_elements = 32 },
    .{ .name = "Q8_1", .enum_value = 9, .block_size = 36, .block_elements = 32 },
    .{ .name = "Q2_K", .enum_value = 10, .block_size = 84, .block_elements = 256 },
    .{ .name = "Q3_K", .enum_value = 11, .block_size = 110, .block_elements = 256 },
    .{ .name = "Q4_K", .enum_value = 12, .block_size = 144, .block_elements = 256 },
    .{ .name = "Q5_K", .enum_value = 13, .block_size = 176, .block_elements = 256 },
    .{ .name = "Q6_K", .enum_value = 14, .block_size = 210, .block_elements = 256 },
    .{ .name = "Q8_K", .enum_value = 15, .block_size = 292, .block_elements = 256 },
    .{ .name = "I8", .enum_value = 24, .block_size = 1, .block_elements = 1 },
    .{ .name = "I16", .enum_value = 25, .block_size = 2, .block_elements = 1 },
    .{ .name = "I32", .enum_value = 26, .block_size = 4, .block_elements = 1 },
    .{ .name = "I64", .enum_value = 27, .block_size = 8, .block_elements = 1 },
    .{ .name = "F64", .enum_value = 28, .block_size = 8, .block_elements = 1 },
    .{ .name = "BF16", .enum_value = 30, .block_size = 2, .block_elements = 1 },
};

// ============================================================================
// Embedded facts (from model_arch.mg)
// ============================================================================

const embedded_arch_info = [_]ArchInfo{
    .{
        .name = "llama",
        .description = "LLaMA family (LLaMA 1/2/3, Mistral, etc.)",
        .attention_type = "gqa",
        .norm_type = "rms_norm",
        .activation = "silu",
        .has_bias = false,
    },
    .{
        .name = "phi2",
        .description = "Microsoft Phi-2",
        .attention_type = "mha",
        .norm_type = "layer_norm",
        .activation = "gelu",
        .has_bias = true,
    },
    .{
        .name = "phi3",
        .description = "Microsoft Phi-3",
        .attention_type = "gqa",
        .norm_type = "rms_norm",
        .activation = "silu",
        .has_bias = false,
    },
    .{
        .name = "gemma",
        .description = "Google Gemma",
        .attention_type = "mqa",
        .norm_type = "rms_norm",
        .activation = "gelu",
        .has_bias = false,
    },
};

const embedded_model_config_info = [_]ModelConfigInfo{
    .{ .name = "llama-7b", .arch = "llama", .n_layers = 32, .n_heads = 32, .n_kv_heads = 32, .dim = 4096, .ff_dim = 11008, .vocab_size = 32000, .context_length = 4096 },
    .{ .name = "llama-13b", .arch = "llama", .n_layers = 40, .n_heads = 40, .n_kv_heads = 40, .dim = 5120, .ff_dim = 13824, .vocab_size = 32000, .context_length = 4096 },
    .{ .name = "llama-70b", .arch = "llama", .n_layers = 80, .n_heads = 64, .n_kv_heads = 8, .dim = 8192, .ff_dim = 28672, .vocab_size = 32000, .context_length = 4096 },
    .{ .name = "llama-3-8b", .arch = "llama", .n_layers = 32, .n_heads = 32, .n_kv_heads = 8, .dim = 4096, .ff_dim = 14336, .vocab_size = 128256, .context_length = 8192 },
    .{ .name = "mistral-7b", .arch = "llama", .n_layers = 32, .n_heads = 32, .n_kv_heads = 8, .dim = 4096, .ff_dim = 14336, .vocab_size = 32000, .context_length = 32768 },
    .{ .name = "phi-2", .arch = "phi2", .n_layers = 32, .n_heads = 32, .n_kv_heads = 32, .dim = 2560, .ff_dim = 10240, .vocab_size = 51200, .context_length = 2048 },
    .{ .name = "phi-3-mini", .arch = "phi3", .n_layers = 32, .n_heads = 32, .n_kv_heads = 8, .dim = 3072, .ff_dim = 8192, .vocab_size = 32064, .context_length = 4096 },
    .{ .name = "gemma-2b", .arch = "gemma", .n_layers = 18, .n_heads = 8, .n_kv_heads = 1, .dim = 2048, .ff_dim = 16384, .vocab_size = 256128, .context_length = 8192 },
    .{ .name = "gemma-7b", .arch = "gemma", .n_layers = 28, .n_heads = 16, .n_kv_heads = 1, .dim = 3072, .ff_dim = 24576, .vocab_size = 256128, .context_length = 8192 },
};

const embedded_tensor_patterns = [_]TensorPatternInfo{
    .{ .arch = "llama", .pattern = "token_embd.weight", .description = "Token embedding matrix" },
    .{ .arch = "llama", .pattern = "blk.{N}.attn_q.weight", .description = "Query projection" },
    .{ .arch = "llama", .pattern = "blk.{N}.attn_k.weight", .description = "Key projection" },
    .{ .arch = "llama", .pattern = "blk.{N}.attn_v.weight", .description = "Value projection" },
    .{ .arch = "llama", .pattern = "blk.{N}.attn_output.weight", .description = "Output projection" },
    .{ .arch = "llama", .pattern = "blk.{N}.attn_norm.weight", .description = "Pre-attention RMS norm" },
    .{ .arch = "llama", .pattern = "blk.{N}.ffn_gate.weight", .description = "FFN gate (SiLU)" },
    .{ .arch = "llama", .pattern = "blk.{N}.ffn_up.weight", .description = "FFN up projection" },
    .{ .arch = "llama", .pattern = "blk.{N}.ffn_down.weight", .description = "FFN down projection" },
    .{ .arch = "llama", .pattern = "blk.{N}.ffn_norm.weight", .description = "Pre-FFN RMS norm" },
    .{ .arch = "llama", .pattern = "output_norm.weight", .description = "Final RMS norm" },
    .{ .arch = "llama", .pattern = "output.weight", .description = "Output projection / LM head" },
    .{ .arch = "phi2", .pattern = "token_embd.weight", .description = "Token embedding matrix" },
    .{ .arch = "phi2", .pattern = "blk.{N}.attn_qkv.weight", .description = "QKV combined projection" },
    .{ .arch = "phi2", .pattern = "blk.{N}.attn_output.weight", .description = "Output projection" },
    .{ .arch = "phi2", .pattern = "blk.{N}.attn_norm.weight", .description = "Attention layer norm" },
    .{ .arch = "phi2", .pattern = "blk.{N}.ffn_up.weight", .description = "FFN up projection" },
    .{ .arch = "phi2", .pattern = "blk.{N}.ffn_down.weight", .description = "FFN down projection" },
    .{ .arch = "phi2", .pattern = "output_norm.weight", .description = "Final layer norm" },
    .{ .arch = "phi2", .pattern = "output.weight", .description = "Output projection" },
};

// JSON response types for HTTP queries
const JsonFact = struct {
    predicate: []const u8,
    args: []const std.json.Value,
};

// Placeholder for raw fact storage
const embedded_dtypes = [_]Fact{};
const embedded_archs = [_]Fact{};
const embedded_model_configs = [_]Fact{};

// ============================================================================
// Tests
// ============================================================================

test "mangle client basic queries" {
    var client = Client.init(std.testing.allocator, .{});
    defer client.deinit();

    // Query data types
    const dtypes = try client.getDataTypes();
    try std.testing.expect(dtypes.len > 0);

    // Query specific type
    const f32_info = client.getDataType("F32");
    try std.testing.expect(f32_info != null);
    try std.testing.expectEqual(@as(u32, 0), f32_info.?.enum_value);
    try std.testing.expectEqual(@as(usize, 4), f32_info.?.block_size);

    // Query Q4_K
    const q4k_info = client.getDataType("Q4_K");
    try std.testing.expect(q4k_info != null);
    try std.testing.expectEqual(@as(usize, 144), q4k_info.?.block_size);
    try std.testing.expectEqual(@as(usize, 256), q4k_info.?.block_elements);
}

test "mangle client model configs" {
    var client = Client.init(std.testing.allocator, .{});
    defer client.deinit();

    // Query Phi-2 config
    const phi2 = client.getModelConfig("phi-2");
    try std.testing.expect(phi2 != null);
    try std.testing.expectEqual(@as(u32, 32), phi2.?.n_layers);
    try std.testing.expectEqual(@as(u32, 2560), phi2.?.dim);
    try std.testing.expectEqual(@as(u32, 51200), phi2.?.vocab_size);

    // Query LLaMA-7B
    const llama7b = client.getModelConfig("llama-7b");
    try std.testing.expect(llama7b != null);
    try std.testing.expectEqual(@as(u32, 32), llama7b.?.n_heads);
}