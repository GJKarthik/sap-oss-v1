//! GGUF Model Loader
//!
//! Loads GGUF format models (llama.cpp compatible) and extracts:
//! - Model configuration (layers, dims, vocab)
//! - Tokenizer vocabulary
//! - Q4_K_M quantized weights
//!
//! Reference: https://github.com/ggerganov/ggml/blob/master/docs/gguf.md

const std = @import("std");
const Allocator = std.mem.Allocator;
const mojo_bridge = @import("mojo_bridge.zig");

// =============================================================================
// GGUF Magic and Version
// =============================================================================

const GGUF_MAGIC: u32 = 0x46554747; // "GGUF" in little-endian
const GGUF_VERSION_V3: u32 = 3;

// =============================================================================
// GGUF Types
// =============================================================================

pub const GGUFType = enum(u32) {
    UINT8 = 0,
    INT8 = 1,
    UINT16 = 2,
    INT16 = 3,
    UINT32 = 4,
    INT32 = 5,
    FLOAT32 = 6,
    BOOL = 7,
    STRING = 8,
    ARRAY = 9,
    UINT64 = 10,
    INT64 = 11,
    FLOAT64 = 12,
};

pub const GGMLType = enum(u32) {
    F32 = 0,
    F16 = 1,
    Q4_0 = 2,
    Q4_1 = 3,
    Q5_0 = 6,
    Q5_1 = 7,
    Q8_0 = 8,
    Q8_1 = 9,
    Q2_K = 10,
    Q3_K = 11,
    Q4_K = 12,
    Q5_K = 13,
    Q6_K = 14,
    Q8_K = 15,
    IQ2_XXS = 16,
    IQ2_XS = 17,
    IQ3_XXS = 18,
    IQ1_S = 19,
    IQ4_NL = 20,
    IQ3_S = 21,
    IQ2_S = 22,
    IQ4_XS = 23,
    I8 = 24,
    I16 = 25,
    I32 = 26,
    I64 = 27,
    F64 = 28,
    BF16 = 30,

    pub fn blockSize(self: GGMLType) u32 {
        return switch (self) {
            .Q4_K => 256,
            .Q4_0, .Q4_1 => 32,
            .Q5_0, .Q5_1 => 32,
            .Q8_0, .Q8_1, .Q8_K => 256,
            .Q2_K, .Q3_K, .Q5_K, .Q6_K => 256,
            else => 1,
        };
    }

    pub fn typeSize(self: GGMLType) u32 {
        return switch (self) {
            .F32, .I32 => 4,
            .F16, .BF16, .I16 => 2,
            .Q4_K => 144, // Per block of 256
            .Q4_0 => 18, // Per block of 32
            .Q4_1 => 20,
            .Q8_0 => 34,
            .Q8_K => 292,
            .I8 => 1,
            else => 1,
        };
    }
};

// =============================================================================
// GGUF Header
// =============================================================================

pub const GGUFHeader = struct {
    magic: u32,
    version: u32,
    tensor_count: u64,
    metadata_kv_count: u64,
};

pub const GGUFString = struct {
    len: u64,
    data: []const u8,
};

// =============================================================================
// GGUF Tensor Info
// =============================================================================

pub const GGUFTensorInfo = struct {
    name: []const u8,
    n_dims: u32,
    dims: [4]u64,
    type_id: GGMLType,
    offset: u64,

    pub fn numElements(self: GGUFTensorInfo) u64 {
        var total: u64 = 1;
        for (0..self.n_dims) |i| {
            total *= self.dims[i];
        }
        return total;
    }

    pub fn dataSize(self: GGUFTensorInfo) u64 {
        const elements = self.numElements();
        const block_size = self.type_id.blockSize();
        const type_size = self.type_id.typeSize();
        return (elements / block_size) * type_size;
    }
};

// =============================================================================
// GGUF Model Configuration
// =============================================================================

pub const GGUFModelConfig = struct {
    arch: []const u8 = "llama",
    vocab_size: u32 = 32000,
    embed_dim: u32 = 2048,
    num_heads: u32 = 32,
    num_kv_heads: u32 = 8,
    num_layers: u32 = 22,
    ffn_dim: u32 = 5632,
    max_seq_len: u32 = 4096,
    rope_base: f32 = 10000.0,
    layer_norm_eps: f32 = 1e-5,
};

// =============================================================================
// GGUF Loader
// =============================================================================

pub const ModelLayout = struct {
    arch_name: []const u8,

    // Metadata Key Strings
    embd_len_key: []const u8,
    block_count_key: []const u8,
    head_count_key: []const u8,
    head_count_kv_key: []const u8,
    ffn_len_key: []const u8,
    ctx_len_key: []const u8,

    // Tensor Names / Formatting
    token_embd_name: []const u8,
    output_norm_name: []const u8,
    output_name: []const u8,

    blk_attn_q_fmt: []const u8,
    blk_attn_k_fmt: []const u8,
    blk_attn_v_fmt: []const u8,
    blk_attn_o_fmt: []const u8,
    blk_ffn_gate_fmt: []const u8,
    blk_ffn_up_fmt: []const u8,
    blk_ffn_down_fmt: []const u8,
    blk_attn_norm_fmt: []const u8,
    blk_ffn_norm_fmt: []const u8,
};

pub const LlamaLayout = ModelLayout{
    .arch_name = "llama",
    .embd_len_key = "llama.embedding_length",
    .block_count_key = "llama.block_count",
    .head_count_key = "llama.attention.head_count",
    .head_count_kv_key = "llama.attention.head_count_kv",
    .ffn_len_key = "llama.feed_forward_length",
    .ctx_len_key = "llama.context_length",

    .token_embd_name = "token_embd.weight",
    .output_norm_name = "output_norm.weight",
    .output_name = "output.weight",

    .blk_attn_q_fmt = "blk.{d}.attn_q.weight",
    .blk_attn_k_fmt = "blk.{d}.attn_k.weight",
    .blk_attn_v_fmt = "blk.{d}.attn_v.weight",
    .blk_attn_o_fmt = "blk.{d}.attn_output.weight",
    .blk_ffn_gate_fmt = "blk.{d}.ffn_gate.weight",
    .blk_ffn_up_fmt = "blk.{d}.ffn_up.weight",
    .blk_ffn_down_fmt = "blk.{d}.ffn_down.weight",
    .blk_attn_norm_fmt = "blk.{d}.attn_norm.weight",
    .blk_ffn_norm_fmt = "blk.{d}.ffn_norm.weight",
};

pub const Phi2Layout = ModelLayout{
    .arch_name = "phi2",
    .embd_len_key = "phi2.embedding_length",
    .block_count_key = "phi2.block_count",
    .head_count_key = "phi2.attention.head_count",
    .head_count_kv_key = "phi2.attention.head_count_kv",
    .ffn_len_key = "phi2.feed_forward_length",
    .ctx_len_key = "phi2.context_length",

    .token_embd_name = "token_embd.weight",
    .output_norm_name = "output_norm.weight",
    .output_name = "output.weight",

    .blk_attn_q_fmt = "blk.{d}.attn_q.weight",
    .blk_attn_k_fmt = "blk.{d}.attn_k.weight",
    .blk_attn_v_fmt = "blk.{d}.attn_v.weight",
    .blk_attn_o_fmt = "blk.{d}.attn_output.weight",
    .blk_ffn_gate_fmt = "blk.{d}.ffn_up_proj.weight", // phi-specific
    .blk_ffn_up_fmt = "blk.{d}.ffn_up.weight", // depends on quantization script
    .blk_ffn_down_fmt = "blk.{d}.ffn_down_proj.weight",
    .blk_attn_norm_fmt = "blk.{d}.attn_norm.weight",
    .blk_ffn_norm_fmt = "blk.{d}.ffn_norm.weight",
};

pub fn getLayoutForArch(arch: []const u8) ModelLayout {
    if (std.mem.eql(u8, arch, "llama")) return LlamaLayout;
    if (std.mem.eql(u8, arch, "phi2")) return Phi2Layout;
    return LlamaLayout; // default
}

pub const GGUFLoader = struct {
    allocator: Allocator,
    file: std.fs.File,
    header: GGUFHeader,
    config: GGUFModelConfig,
    layout: ModelLayout,
    tensor_infos: std.ArrayListUnmanaged(GGUFTensorInfo),
    metadata: std.StringHashMap(MetaValue),
    data_offset: u64,

    const MetaValue = union(enum) {
        uint32: u32,
        int32: i32,
        float32: f32,
        uint64: u64,
        int64: i64,
        float64: f64,
        bool_val: bool,
        string: []const u8,
        array_uint32: []u32,
        array_string: [][]const u8,
    };

    const Self = @This();

    pub fn open(allocator: Allocator, path: []const u8) !Self {
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();

        var self = Self{
            .allocator = allocator,
            .file = file,
            .header = undefined,
            .config = GGUFModelConfig{},
            .layout = LlamaLayout,
            .tensor_infos = .empty,
            .metadata = std.StringHashMap(MetaValue).init(allocator),
            .data_offset = 0,
        };

        // Read header
        try self.readHeader();

        // Read metadata
        try self.readMetadata();

        // Read tensor infos
        try self.readTensorInfos();

        // Extract config from metadata
        self.extractConfig();

        return self;
    }

    pub fn close(self: *Self) void {
        self.file.close();
        self.tensor_infos.deinit(self.allocator);

        var iter = self.metadata.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .string => |s| self.allocator.free(s),
                .array_string => |arr| {
                    for (arr) |s| self.allocator.free(s);
                    self.allocator.free(arr);
                },
                .array_uint32 => |arr| self.allocator.free(arr),
                else => {},
            }
        }
        self.metadata.deinit();
    }

    fn readHeader(self: *Self) !void {
        const reader = self.file.reader();

        self.header.magic = try reader.readInt(u32, .little);
        if (self.header.magic != GGUF_MAGIC) {
            return error.InvalidGGUFMagic;
        }

        self.header.version = try reader.readInt(u32, .little);
        if (self.header.version < GGUF_VERSION_V3) {
            return error.UnsupportedGGUFVersion;
        }

        self.header.tensor_count = try reader.readInt(u64, .little);
        self.header.metadata_kv_count = try reader.readInt(u64, .little);
    }

    fn readString(self: *Self) ![]const u8 {
        const reader = self.file.reader();
        const len = try reader.readInt(u64, .little);
        const str = try self.allocator.alloc(u8, len);
        _ = try reader.readAll(str);
        return str;
    }

    fn readMetadata(self: *Self) !void {
        const reader = self.file.reader();

        for (0..self.header.metadata_kv_count) |_| {
            const key = try self.readString();
            errdefer self.allocator.free(key);

            const type_id = try reader.readInt(u32, .little);
            const gguf_type: GGUFType = @enumFromInt(type_id);

            const value: MetaValue = switch (gguf_type) {
                .UINT32 => .{ .uint32 = try reader.readInt(u32, .little) },
                .INT32 => .{ .int32 = try reader.readInt(i32, .little) },
                .FLOAT32 => .{ .float32 = @bitCast(try reader.readInt(u32, .little)) },
                .UINT64 => .{ .uint64 = try reader.readInt(u64, .little) },
                .INT64 => .{ .int64 = try reader.readInt(i64, .little) },
                .FLOAT64 => .{ .float64 = @bitCast(try reader.readInt(u64, .little)) },
                .BOOL => .{ .bool_val = try reader.readInt(u8, .little) != 0 },
                .STRING => .{ .string = try self.readString() },
                .ARRAY => blk: {
                    const arr_type = try reader.readInt(u32, .little);
                    const arr_len = try reader.readInt(u64, .little);

                    if (arr_type == @intFromEnum(GGUFType.UINT32)) {
                        var arr = try self.allocator.alloc(u32, arr_len);
                        for (arr) |*v| {
                            v.* = try reader.readInt(u32, .little);
                        }
                        break :blk .{ .array_uint32 = arr };
                    } else if (arr_type == @intFromEnum(GGUFType.STRING)) {
                        var arr = try self.allocator.alloc([]const u8, arr_len);
                        for (arr) |*v| {
                            v.* = try self.readString();
                        }
                        break :blk .{ .array_string = arr };
                    } else {
                        // Skip unknown array types
                        for (0..arr_len) |_| {
                            _ = try reader.readInt(u64, .little);
                        }
                        break :blk .{ .uint32 = 0 };
                    }
                },
                else => .{ .uint32 = try reader.readInt(u32, .little) },
            };

            try self.metadata.put(key, value);
        }
    }

    fn readTensorInfos(self: *Self) !void {
        const reader = self.file.reader();

        for (0..self.header.tensor_count) |_| {
            var info = GGUFTensorInfo{
                .name = try self.readString(),
                .n_dims = try reader.readInt(u32, .little),
                .dims = [4]u64{ 1, 1, 1, 1 },
                .type_id = undefined,
                .offset = undefined,
            };

            for (0..info.n_dims) |i| {
                info.dims[i] = try reader.readInt(u64, .little);
            }

            info.type_id = @enumFromInt(try reader.readInt(u32, .little));
            info.offset = try reader.readInt(u64, .little);

            try self.tensor_infos.append(self.allocator, info);
        }

        // Calculate data offset (aligned to 32 bytes)
        const current_pos = try self.file.getPos();
        self.data_offset = (current_pos + 31) & ~@as(u64, 31);
    }

    fn extractConfig(self: *Self) void {
        // Extract arch
        if (self.metadata.get("general.architecture")) |v| {
            if (v == .string) self.config.arch = v.string;
        }

        // Setup layout based on arch
        self.layout = getLayoutForArch(self.config.arch);

        // Extract dimensions
        if (self.getMetaU32(self.layout.embd_len_key)) |v| self.config.embed_dim = v;
        if (self.getMetaU32(self.layout.block_count_key)) |v| self.config.num_layers = v;
        if (self.getMetaU32(self.layout.head_count_key)) |v| self.config.num_heads = v;
        if (self.getMetaU32(self.layout.head_count_kv_key)) |v| self.config.num_kv_heads = v;
        if (self.getMetaU32(self.layout.ffn_len_key)) |v| self.config.ffn_dim = v;
        if (self.getMetaU32(self.layout.ctx_len_key)) |v| self.config.max_seq_len = v;

        // Vocab from tokenizer
        if (self.metadata.get("tokenizer.ggml.tokens")) |v| {
            if (v == .array_string) self.config.vocab_size = @intCast(v.array_string.len);
        }
    }

    fn getMetaU32(self: *Self, key: []const u8) ?u32 {
        if (self.metadata.get(key)) |v| {
            return switch (v) {
                .uint32 => v.uint32,
                .int32 => @intCast(v.int32),
                else => null,
            };
        }
        return null;
    }

    /// Find tensor by name
    pub fn findTensor(self: *Self, name: []const u8) ?GGUFTensorInfo {
        for (self.tensor_infos.items) |info| {
            if (std.mem.eql(u8, info.name, name)) {
                return info;
            }
        }
        return null;
    }

    /// Read tensor data
    pub fn readTensorData(self: *Self, info: GGUFTensorInfo) ![]u8 {
        const size = info.dataSize();
        var data = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(data);

        try self.file.seekTo(self.data_offset + info.offset);
        _ = try self.file.readAll(data);

        return data;
    }

    /// Load all weights into Mojo model
    pub fn loadIntoModel(self: *Self, model: *mojo_bridge.MojoModel) !void {
        std.log.info("Loading GGUF weights into Mojo model...", .{});

        // Load embedding
        if (self.findTensor(self.layout.token_embd_name)) |info| {
            const data = try self.readTensorData(info);
            defer self.allocator.free(data);

            if (info.type_id == .F32) {
                try model.loadEmbedding(@alignCast(std.mem.bytesAsSlice(f32, data)));
            }
        }

        // Load layers
        for (0..self.config.num_layers) |layer_idx| {
            try self.loadLayer(model, @intCast(layer_idx));
        }

        // Load final weights
        if (self.findTensor(self.layout.output_norm_name)) |ln_info| {
            if (self.findTensor(self.layout.output_name)) |lm_info| {
                const ln_data = try self.readTensorData(ln_info);
                defer self.allocator.free(ln_data);
                const lm_data = try self.readTensorData(lm_info);
                defer self.allocator.free(lm_data);

                if (ln_info.type_id == .F32 and lm_info.type_id == .F32) {
                    try model.loadFinal(
                        @alignCast(std.mem.bytesAsSlice(f32, ln_data)),
                        @alignCast(std.mem.bytesAsSlice(f32, lm_data)),
                    );
                }
            }
        }

        std.log.info("GGUF weights loaded successfully", .{});
    }

    fn loadLayer(self: *Self, model: *mojo_bridge.MojoModel, layer_idx: u32) !void {
        var buf: [64]u8 = undefined;

        // Format tensor names
        // Try to load Q4_K weights
        const wq_name = std.fmt.bufPrint(&buf, self.layout.blk_attn_q_fmt, .{layer_idx}) catch unreachable;
        var wq_data: []u8 = &[_]u8{};
        if (self.findTensor(wq_name)) |info| wq_data = try self.readTensorData(info);

        const wk_name = std.fmt.bufPrint(&buf, self.layout.blk_attn_k_fmt, .{layer_idx}) catch unreachable;
        var wk_data: []u8 = &[_]u8{};
        if (self.findTensor(wk_name)) |info| wk_data = try self.readTensorData(info);

        const wv_name = std.fmt.bufPrint(&buf, self.layout.blk_attn_v_fmt, .{layer_idx}) catch unreachable;
        var wv_data: []u8 = &[_]u8{};
        if (self.findTensor(wv_name)) |info| wv_data = try self.readTensorData(info);

        const wo_name = std.fmt.bufPrint(&buf, self.layout.blk_attn_o_fmt, .{layer_idx}) catch unreachable;
        var wo_data: []u8 = &[_]u8{};
        if (self.findTensor(wo_name)) |info| wo_data = try self.readTensorData(info);

        const wgate_name = std.fmt.bufPrint(&buf, self.layout.blk_ffn_gate_fmt, .{layer_idx}) catch unreachable;
        var wgate_data: []u8 = &[_]u8{};
        if (self.findTensor(wgate_name)) |info| wgate_data = try self.readTensorData(info);

        const wup_name = std.fmt.bufPrint(&buf, self.layout.blk_ffn_up_fmt, .{layer_idx}) catch unreachable;
        var wup_data: []u8 = &[_]u8{};
        if (self.findTensor(wup_name)) |info| wup_data = try self.readTensorData(info);

        const wdown_name = std.fmt.bufPrint(&buf, self.layout.blk_ffn_down_fmt, .{layer_idx}) catch unreachable;
        var wdown_data: []u8 = &[_]u8{};
        if (self.findTensor(wdown_name)) |info| wdown_data = try self.readTensorData(info);

        // Read tensor data
        defer {
            if (wq_data.len > 0) self.allocator.free(wq_data);
            if (wk_data.len > 0) self.allocator.free(wk_data);
            if (wv_data.len > 0) self.allocator.free(wv_data);
            if (wo_data.len > 0) self.allocator.free(wo_data);
            if (wgate_data.len > 0) self.allocator.free(wgate_data);
            if (wup_data.len > 0) self.allocator.free(wup_data);
            if (wdown_data.len > 0) self.allocator.free(wdown_data);
        }

        // Load Q4_K weights
        if (wq_data.len > 0) {
            try model.loadLayerQ4(
                layer_idx,
                wq_data,
                wk_data,
                wv_data,
                wo_data,
                wgate_data,
                wup_data,
                wdown_data,
            );
        }

        // Load layer norms (FP32)
        const ln_attn_name = std.fmt.bufPrint(&buf, self.layout.blk_attn_norm_fmt, .{layer_idx}) catch unreachable;

        // Ensure string is copied as we reuse `buf` for the second string
        var ln_attn_name_buf: [128]u8 = undefined;
        std.mem.copyForwards(u8, &ln_attn_name_buf, ln_attn_name);
        const ln_attn_name_copy = ln_attn_name_buf[0..ln_attn_name.len];

        const ln_ffn_name = std.fmt.bufPrint(&buf, self.layout.blk_ffn_norm_fmt, .{layer_idx}) catch unreachable;

        if (self.findTensor(ln_attn_name_copy)) |ln_attn_info| {
            if (self.findTensor(ln_ffn_name)) |ln_ffn_info| {
                const ln_attn_data = try self.readTensorData(ln_attn_info);
                defer self.allocator.free(ln_attn_data);
                const ln_ffn_data = try self.readTensorData(ln_ffn_info);
                defer self.allocator.free(ln_ffn_data);

                if (ln_attn_info.type_id == .F32 and ln_ffn_info.type_id == .F32) {
                    try model.loadLayerNorm(
                        layer_idx,
                        @alignCast(std.mem.bytesAsSlice(f32, ln_attn_data)),
                        @alignCast(std.mem.bytesAsSlice(f32, ln_ffn_data)),
                    );
                }
            }
        }
    }

    /// Get tokenizer vocab
    pub fn getVocab(self: *Self) ?[][]const u8 {
        if (self.metadata.get("tokenizer.ggml.tokens")) |v| {
            if (v == .array_string) return v.array_string;
        }
        return null;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "gguf magic" {
    try std.testing.expectEqual(GGUF_MAGIC, 0x46554747);
}

test "block sizes" {
    try std.testing.expectEqual(@as(u32, 256), GGMLType.Q4_K.blockSize());
    try std.testing.expectEqual(@as(u32, 144), GGMLType.Q4_K.typeSize());
}
