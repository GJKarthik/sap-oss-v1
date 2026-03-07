// =============================================================================
// Mojo FFI Bridge
//
// Loads the Mojo-based Private LLM inference library (libpllm) via dlopen
// and provides a Zig-native API for LLM inference.
//
// This bridge replaces the llama.cpp dependency with our custom Mojo kernels.
// =============================================================================

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Error Codes (from pllm.h)
// =============================================================================

pub const PLLM_SUCCESS: c_int = 0;
pub const PLLM_ERROR_NULL_POINTER: c_int = -1;
pub const PLLM_ERROR_INVALID_HANDLE: c_int = -2;
pub const PLLM_ERROR_OUT_OF_MEMORY: c_int = -3;
pub const PLLM_ERROR_INVALID_CONFIG: c_int = -4;
pub const PLLM_ERROR_LOAD_FAILED: c_int = -5;
pub const PLLM_ERROR_INFERENCE_FAILED: c_int = -6;
pub const PLLM_ERROR_BUFFER_TOO_SMALL: c_int = -7;

// =============================================================================
// Library Path
// =============================================================================

const lib_name = switch (builtin.os.tag) {
    .macos => "libpllm.dylib",
    .linux => "libpllm.so",
    .windows => "pllm.dll",
    else => "libpllm.so",
};

// Search paths for the library
const lib_search_paths = [_][]const u8{
    "../mojo/lib/", // Relative to zig binary
    "../../mojo/lib/", // Alternative relative path
    "/usr/local/lib/", // System path
    "./", // Current directory
};

// =============================================================================
// Function Pointer Types
// =============================================================================

const ConfigHandle = ?*anyopaque;
const ModelHandle = ?*anyopaque;

// Configuration functions
const PllmConfigCreate = *const fn (c_int, c_int, c_int, c_int, c_int, c_int, c_int) callconv(.c) ConfigHandle;
const PllmConfigCreateLlama1b = *const fn () callconv(.c) ConfigHandle;
const PllmConfigCreatePhi2 = *const fn () callconv(.c) ConfigHandle;
const PllmConfigFree = *const fn (ConfigHandle) callconv(.c) c_int;

// Model functions
const PllmModelCreate = *const fn (ConfigHandle) callconv(.c) ModelHandle;
const PllmModelLoadEmbedding = *const fn (ModelHandle, [*]const f32, usize) callconv(.c) c_int;
const PllmModelLoadLayerQ4 = *const fn (
    ModelHandle,
    c_int,
    [*]const u8,
    usize,
    [*]const u8,
    usize,
    [*]const u8,
    usize,
    [*]const u8,
    usize,
    [*]const u8,
    usize,
    [*]const u8,
    usize,
    [*]const u8,
    usize,
) callconv(.c) c_int;
const PllmModelLoadLayerNorm = *const fn (ModelHandle, c_int, [*]const f32, [*]const f32, c_int) callconv(.c) c_int;
const PllmModelLoadFinal = *const fn (ModelHandle, [*]const f32, [*]const f32) callconv(.c) c_int;
const PllmModelFree = *const fn (ModelHandle) callconv(.c) c_int;

// Inference functions
const PllmGenerate = *const fn (
    ModelHandle,
    [*]const c_int,
    c_int,
    [*]c_int,
    c_int,
    c_int,
    f32,
    f32,
    c_int,
) callconv(.c) c_int;

// Info functions
const PllmModelMemoryMb = *const fn (ModelHandle) callconv(.c) f32;
const PllmGetVocabSize = *const fn (ModelHandle) callconv(.c) c_int;
const PllmGetEmbedDim = *const fn (ModelHandle) callconv(.c) c_int;
const PllmGetNumLayers = *const fn (ModelHandle) callconv(.c) c_int;
const PllmGetMaxSeqLen = *const fn (ModelHandle) callconv(.c) c_int;

// Version functions
const PllmVersionMajor = *const fn () callconv(.c) c_int;
const PllmVersionMinor = *const fn () callconv(.c) c_int;
const PllmVersionPatch = *const fn () callconv(.c) c_int;

// =============================================================================
// Mojo Library Handle
// =============================================================================

pub const MojoLibrary = struct {
    handle: std.DynLib,

    // Function pointers
    config_create: PllmConfigCreate,
    config_create_llama_1b: PllmConfigCreateLlama1b,
    config_create_phi2: PllmConfigCreatePhi2,
    config_free: PllmConfigFree,

    model_create: PllmModelCreate,
    model_load_embedding: PllmModelLoadEmbedding,
    model_load_layer_q4: PllmModelLoadLayerQ4,
    model_load_layer_norm: PllmModelLoadLayerNorm,
    model_load_final: PllmModelLoadFinal,
    model_free: PllmModelFree,

    generate: PllmGenerate,

    model_memory_mb: PllmModelMemoryMb,
    get_vocab_size: PllmGetVocabSize,
    get_embed_dim: PllmGetEmbedDim,
    get_num_layers: PllmGetNumLayers,
    get_max_seq_len: PllmGetMaxSeqLen,

    version_major: PllmVersionMajor,
    version_minor: PllmVersionMinor,
    version_patch: PllmVersionPatch,

    const Self = @This();

    pub fn load(search_path: ?[]const u8) !Self {
        var lib_path: []const u8 = undefined;
        var found = false;

        // Try search path first
        if (search_path) |path| {
            var buf: [512]u8 = undefined;
            const full_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ path, lib_name }) catch unreachable;
            if (std.fs.cwd().access(full_path, .{})) |_| {
                lib_path = full_path;
                found = true;
            } else |_| {}
        }

        // Try default search paths
        if (!found) {
            for (lib_search_paths) |path| {
                var buf: [512]u8 = undefined;
                const full_path = std.fmt.bufPrint(&buf, "{s}{s}", .{ path, lib_name }) catch continue;
                if (std.fs.cwd().access(full_path, .{})) |_| {
                    lib_path = full_path;
                    found = true;
                    break;
                } else |_| {}
            }
        }

        // Try just the library name (system paths)
        if (!found) {
            lib_path = lib_name;
        }

        var handle = std.DynLib.open(lib_path) catch |err| {
            std.log.err("Failed to load {s}: {}", .{ lib_path, err });
            return error.LibraryNotFound;
        };

        return Self{
            .handle = handle,
            // Configuration
            .config_create = handle.lookup(PllmConfigCreate, "pllm_config_create") orelse return error.SymbolNotFound,
            .config_create_llama_1b = handle.lookup(PllmConfigCreateLlama1b, "pllm_config_create_llama_1b") orelse return error.SymbolNotFound,
            .config_create_phi2 = handle.lookup(PllmConfigCreatePhi2, "pllm_config_create_phi2") orelse return error.SymbolNotFound,
            .config_free = handle.lookup(PllmConfigFree, "pllm_config_free") orelse return error.SymbolNotFound,
            // Model
            .model_create = handle.lookup(PllmModelCreate, "pllm_model_create") orelse return error.SymbolNotFound,
            .model_load_embedding = handle.lookup(PllmModelLoadEmbedding, "pllm_model_load_embedding") orelse return error.SymbolNotFound,
            .model_load_layer_q4 = handle.lookup(PllmModelLoadLayerQ4, "pllm_model_load_layer_q4") orelse return error.SymbolNotFound,
            .model_load_layer_norm = handle.lookup(PllmModelLoadLayerNorm, "pllm_model_load_layer_norm") orelse return error.SymbolNotFound,
            .model_load_final = handle.lookup(PllmModelLoadFinal, "pllm_model_load_final") orelse return error.SymbolNotFound,
            .model_free = handle.lookup(PllmModelFree, "pllm_model_free") orelse return error.SymbolNotFound,
            // Inference
            .generate = handle.lookup(PllmGenerate, "pllm_generate") orelse return error.SymbolNotFound,
            // Info
            .model_memory_mb = handle.lookup(PllmModelMemoryMb, "pllm_model_memory_mb") orelse return error.SymbolNotFound,
            .get_vocab_size = handle.lookup(PllmGetVocabSize, "pllm_get_vocab_size") orelse return error.SymbolNotFound,
            .get_embed_dim = handle.lookup(PllmGetEmbedDim, "pllm_get_embed_dim") orelse return error.SymbolNotFound,
            .get_num_layers = handle.lookup(PllmGetNumLayers, "pllm_get_num_layers") orelse return error.SymbolNotFound,
            .get_max_seq_len = handle.lookup(PllmGetMaxSeqLen, "pllm_get_max_seq_len") orelse return error.SymbolNotFound,
            // Version
            .version_major = handle.lookup(PllmVersionMajor, "pllm_version_major") orelse return error.SymbolNotFound,
            .version_minor = handle.lookup(PllmVersionMinor, "pllm_version_minor") orelse return error.SymbolNotFound,
            .version_patch = handle.lookup(PllmVersionPatch, "pllm_version_patch") orelse return error.SymbolNotFound,
        };
    }

    pub fn close(self: *Self) void {
        self.handle.close();
    }

    pub fn getVersion(self: Self) struct { major: i32, minor: i32, patch: i32 } {
        return .{
            .major = self.version_major(),
            .minor = self.version_minor(),
            .patch = self.version_patch(),
        };
    }
};

// =============================================================================
// Model Configuration
// =============================================================================

pub const ModelConfig = struct {
    vocab_size: u32 = 32000,
    embed_dim: u32 = 2048,
    num_heads: u32 = 32,
    num_kv_heads: u32 = 8,
    num_layers: u32 = 22,
    ffn_dim: u32 = 5632,
    max_seq_len: u32 = 4096,

    pub const llama_1b = ModelConfig{
        .vocab_size = 32000,
        .embed_dim = 2048,
        .num_heads = 32,
        .num_kv_heads = 8,
        .num_layers = 22,
        .ffn_dim = 5632,
        .max_seq_len = 4096,
    };

    pub const phi2 = ModelConfig{
        .vocab_size = 51200,
        .embed_dim = 2560,
        .num_heads = 32,
        .num_kv_heads = 32,
        .num_layers = 32,
        .ffn_dim = 10240,
        .max_seq_len = 2048,
    };
};

// =============================================================================
// Generation Configuration
// =============================================================================

pub const GenerationConfig = struct {
    max_new_tokens: u32 = 256,
    temperature: f32 = 0.7,
    top_p: f32 = 0.9,
    eos_token_id: u32 = 2,
};

// =============================================================================
// Mojo Model Wrapper
// =============================================================================

pub const MojoModel = struct {
    lib: *MojoLibrary,
    config_handle: ConfigHandle,
    model_handle: ModelHandle,
    config: ModelConfig,

    const Self = @This();

    pub fn init(lib: *MojoLibrary, config: ModelConfig) !Self {
        const config_handle = lib.config_create(
            @intCast(config.vocab_size),
            @intCast(config.embed_dim),
            @intCast(config.num_heads),
            @intCast(config.num_kv_heads),
            @intCast(config.num_layers),
            @intCast(config.ffn_dim),
            @intCast(config.max_seq_len),
        );

        if (config_handle == null) {
            return error.ConfigCreationFailed;
        }

        const model_handle = lib.model_create(config_handle);
        if (model_handle == null) {
            _ = lib.config_free(config_handle);
            return error.ModelCreationFailed;
        }

        return Self{
            .lib = lib,
            .config_handle = config_handle,
            .model_handle = model_handle,
            .config = config,
        };
    }

    pub fn initLlama1b(lib: *MojoLibrary) !Self {
        const config_handle = lib.config_create_llama_1b();
        if (config_handle == null) {
            return error.ConfigCreationFailed;
        }

        const model_handle = lib.model_create(config_handle);
        if (model_handle == null) {
            _ = lib.config_free(config_handle);
            return error.ModelCreationFailed;
        }

        return Self{
            .lib = lib,
            .config_handle = config_handle,
            .model_handle = model_handle,
            .config = ModelConfig.llama_1b,
        };
    }

    pub fn initPhi2(lib: *MojoLibrary) !Self {
        const config_handle = lib.config_create_phi2();
        if (config_handle == null) {
            return error.ConfigCreationFailed;
        }

        const model_handle = lib.model_create(config_handle);
        if (model_handle == null) {
            _ = lib.config_free(config_handle);
            return error.ModelCreationFailed;
        }

        return Self{
            .lib = lib,
            .config_handle = config_handle,
            .model_handle = model_handle,
            .config = ModelConfig.phi2,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self.lib.model_free(self.model_handle);
        _ = self.lib.config_free(self.config_handle);
    }

    pub fn loadEmbedding(self: *Self, data: []const f32) !void {
        const result = self.lib.model_load_embedding(
            self.model_handle,
            data.ptr,
            data.len * @sizeOf(f32),
        );
        if (result != PLLM_SUCCESS) {
            return error.LoadEmbeddingFailed;
        }
    }

    pub fn loadLayerQ4(
        self: *Self,
        layer_idx: u32,
        wq: []const u8,
        wk: []const u8,
        wv: []const u8,
        wo: []const u8,
        w_gate: []const u8,
        w_up: []const u8,
        w_down: []const u8,
    ) !void {
        const result = self.lib.model_load_layer_q4(
            self.model_handle,
            @intCast(layer_idx),
            wq.ptr,
            wq.len,
            wk.ptr,
            wk.len,
            wv.ptr,
            wv.len,
            wo.ptr,
            wo.len,
            w_gate.ptr,
            w_gate.len,
            w_up.ptr,
            w_up.len,
            w_down.ptr,
            w_down.len,
        );
        if (result != PLLM_SUCCESS) {
            return error.LoadLayerFailed;
        }
    }

    pub fn loadLayerNorm(
        self: *Self,
        layer_idx: u32,
        ln_attn: []const f32,
        ln_ffn: []const f32,
    ) !void {
        const result = self.lib.model_load_layer_norm(
            self.model_handle,
            @intCast(layer_idx),
            ln_attn.ptr,
            ln_ffn.ptr,
            @intCast(self.config.embed_dim),
        );
        if (result != PLLM_SUCCESS) {
            return error.LoadLayerNormFailed;
        }
    }

    pub fn loadFinal(self: *Self, ln_final: []const f32, lm_head: []const f32) !void {
        const result = self.lib.model_load_final(
            self.model_handle,
            ln_final.ptr,
            lm_head.ptr,
        );
        if (result != PLLM_SUCCESS) {
            return error.LoadFinalFailed;
        }
    }

    pub fn generate(
        self: *Self,
        input_tokens: []const i32,
        output_buffer: []i32,
        gen_config: GenerationConfig,
    ) !usize {
        const result = self.lib.generate(
            self.model_handle,
            @ptrCast(input_tokens.ptr),
            @intCast(input_tokens.len),
            @ptrCast(output_buffer.ptr),
            @intCast(output_buffer.len),
            @intCast(gen_config.max_new_tokens),
            gen_config.temperature,
            gen_config.top_p,
            @intCast(gen_config.eos_token_id),
        );

        if (result < 0) {
            return switch (result) {
                PLLM_ERROR_NULL_POINTER => error.NullPointer,
                PLLM_ERROR_BUFFER_TOO_SMALL => error.BufferTooSmall,
                PLLM_ERROR_INFERENCE_FAILED => error.InferenceFailed,
                else => error.UnknownError,
            };
        }

        return @intCast(result);
    }

    pub fn memoryMb(self: Self) f32 {
        return self.lib.model_memory_mb(self.model_handle);
    }

    pub fn vocabSize(self: Self) u32 {
        const result = self.lib.get_vocab_size(self.model_handle);
        return if (result > 0) @intCast(result) else 0;
    }

    pub fn embedDim(self: Self) u32 {
        const result = self.lib.get_embed_dim(self.model_handle);
        return if (result > 0) @intCast(result) else 0;
    }

    pub fn numLayers(self: Self) u32 {
        const result = self.lib.get_num_layers(self.model_handle);
        return if (result > 0) @intCast(result) else 0;
    }

    pub fn maxSeqLen(self: Self) u32 {
        const result = self.lib.get_max_seq_len(self.model_handle);
        return if (result > 0) @intCast(result) else 0;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "library loading" {
    var lib = MojoLibrary.load(null) catch |err| {
        std.debug.print("Library not found (expected if not built): {}\n", .{err});
        return;
    };
    defer lib.close();

    const version = lib.getVersion();
    std.debug.print("PLLM version: {}.{}.{}\n", .{ version.major, version.minor, version.patch });

    try std.testing.expect(version.major >= 1);
}

test "model creation" {
    var lib = MojoLibrary.load(null) catch {
        return; // Skip if library not available
    };
    defer lib.close();

    var model = MojoModel.initLlama1b(&lib) catch |err| {
        std.debug.print("Model creation failed: {}\n", .{err});
        return;
    };
    defer model.deinit();

    try std.testing.expectEqual(@as(u32, 32000), model.vocabSize());
    try std.testing.expectEqual(@as(u32, 2048), model.embedDim());
    try std.testing.expectEqual(@as(u32, 22), model.numLayers());
}
