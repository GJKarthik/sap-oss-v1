//! GPU Backend for NVIDIA (CUDA) and Apple Silicon (Metal)
//!
//! Optimized for T4 (Turing), A100 (Ampere) and Apple M1/M2/M3 accelerators.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

// ============================================================================
// GPU Detection
// ============================================================================

pub const GpuType = enum {
    cuda_t4,
    cuda_a100,
    cuda_generic,
    apple_silicon, // M1, M2, M3
    unknown,
};

pub const GpuInfo = struct {
    type: GpuType,
    name: []const u8,
    memory_mb: u32,
    has_tensor_cores: bool,
};

pub fn detectGpu(allocator: Allocator) !GpuInfo {
    if (builtin.os.tag == .macos) {
        return detectMacGpu(allocator);
    } else {
        return detectNvidiaGpu(allocator);
    }
}

fn detectMacGpu(allocator: Allocator) !GpuInfo {
    // On macOS, check sysctl for Apple Silicon
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sysctl", "-n", "machdep.cpu.brand_string" },
        .max_output_bytes = 4096,
    }) catch {
        return GpuInfo{ .type = .unknown, .name = "unknown", .memory_mb = 8192, .has_tensor_cores = false };
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (std.mem.indexOf(u8, result.stdout, "Apple") != null) {
        const name = try allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \n\r\t"));
        // Read actual unified memory size via hw.memsize (returns bytes as u64 string)
        const mem_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "sysctl", "-n", "hw.memsize" },
            .max_output_bytes = 64,
        }) catch null;
        const memory_mb: u32 = if (mem_result) |mr| blk: {
            defer allocator.free(mr.stdout);
            defer allocator.free(mr.stderr);
            const trimmed = std.mem.trim(u8, mr.stdout, " \n\r\t");
            const bytes = std.fmt.parseInt(u64, trimmed, 10) catch break :blk 16384;
            break :blk @intCast(bytes / (1024 * 1024));
        } else 16384;
        return GpuInfo{
            .type = .apple_silicon,
            .name = name,
            .memory_mb = memory_mb,
            .has_tensor_cores = true, // Apple AMX units
        };
    }
    
    return GpuInfo{ .type = .unknown, .name = "intel_mac", .memory_mb = 8192, .has_tensor_cores = false };
}

fn detectNvidiaGpu(allocator: Allocator) !GpuInfo {
    // Run nvidia-smi to detect GPU
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "nvidia-smi",
            "--query-gpu=name,memory.total",
            "--format=csv,noheader,nounits",
        },
        .max_output_bytes = 4096,
    }) catch {
        return GpuInfo{ .type = .unknown, .name = "unknown", .memory_mb = 8192, .has_tensor_cores = false };
    };
    
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    var lines = std.mem.splitSequence(u8, result.stdout, "\n");
    if (lines.next()) |line| {
        var parts = std.mem.splitSequence(u8, line, ", ");
        const name = parts.next() orelse "unknown";
        const mem_str = parts.next() orelse "8192";
        const memory_mb = std.fmt.parseInt(u32, mem_str, 10) catch 8192;
        
        var gtype: GpuType = .cuda_generic;
        if (std.mem.indexOf(u8, name, "T4") != null) gtype = .cuda_t4;
        if (std.mem.indexOf(u8, name, "A100") != null) gtype = .cuda_a100;

        return GpuInfo{
            .type = gtype,
            .name = try allocator.dupe(u8, name),
            .memory_mb = memory_mb,
            .has_tensor_cores = true,
        };
    }
    
    return GpuInfo{ .type = .unknown, .name = "unknown", .memory_mb = 8192, .has_tensor_cores = false };
}

// ============================================================================
// Ollama GPU Orchestration
// ============================================================================

pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

pub const GpuOrchestrator = struct {
    const metal_env = [_]EnvVar{
        .{ .key = "OLLAMA_METAL", .value = "1" },
        .{ .key = "OLLAMA_NUM_GPU", .value = "99" },
    };
    
    const cuda_env = [_]EnvVar{
        .{ .key = "OLLAMA_FLASH_ATTENTION", .value = "1" },
        .{ .key = "OLLAMA_KV_CACHE_TYPE", .value = "q8_0" },
        .{ .key = "CUDA_VISIBLE_DEVICES", .value = "0" },
    };
    
    const empty_env = [_]EnvVar{};
    
    pub fn getEnvVars(info: GpuInfo) []const EnvVar {
        if (info.type == .apple_silicon) {
            return &metal_env;
        } else if (info.type == .cuda_t4 or info.type == .cuda_a100) {
            return &cuda_env;
        }
        return &empty_env;
    }
};

// ============================================================================
// T4-Specific Optimization Config
// ============================================================================

pub const T4Config = struct {
    // Memory optimization
    memory_fraction: f32 = 0.95,  // Use 95% of 16GB
    kv_cache_size_mb: u32 = 4096, // 4GB for KV cache
    
    // Batch settings optimized for T4
    max_batch_size: u32 = 8,       // Sweet spot for T4
    max_sequence_length: u32 = 2048,
    
    // Quantization - T4 excels at INT8
    use_int8_quantization: bool = true,
    use_fp16_compute: bool = true,
    
    // Tensor core utilization
    use_tensor_cores: bool = true,
    tensor_core_alignment: u32 = 8,  // Must be multiple of 8 for tensor cores
    
    // CUDA graphs for reduced kernel launch overhead
    use_cuda_graphs: bool = true,
    
    // Memory pool settings
    enable_memory_pool: bool = true,
    memory_pool_size_mb: u32 = 14336,  // ~14GB pool
    
    // Continuous batching
    enable_continuous_batching: bool = true,
    prefill_chunk_size: u32 = 512,
    
    pub fn forModelSize(size_gb: f32) T4Config {
        var config = T4Config{};
        
        // Adjust based on model size
        if (size_gb <= 7.0) {
            // 7B model fits well on T4
            config.max_batch_size = 8;
            config.max_sequence_length = 4096;
            config.kv_cache_size_mb = 6144;  // 6GB for KV cache
        } else if (size_gb <= 13.0) {
            // 13B model needs INT8 quantization
            config.max_batch_size = 4;
            config.max_sequence_length = 2048;
            config.use_int8_quantization = true;
            config.kv_cache_size_mb = 3072;  // 3GB for KV cache
        } else {
            // Larger models need aggressive optimization
            config.max_batch_size = 2;
            config.max_sequence_length = 1024;
            config.use_int8_quantization = true;
            config.kv_cache_size_mb = 2048;
        }
        
        return config;
    }
};

pub const NvidiaGpu = enum {
    t4,
    a100,
    generic,
    unknown,

    pub fn fromName(name: []const u8) NvidiaGpu {
        if (std.mem.indexOf(u8, name, "T4") != null) return .t4;
        if (std.mem.indexOf(u8, name, "A100") != null) return .a100;
        if (std.mem.indexOf(u8, name, "Tesla") != null or std.mem.indexOf(u8, name, "NVIDIA") != null) return .generic;
        return .unknown;
    }

    pub fn getMemoryMb(self: NvidiaGpu) u32 {
        return switch (self) {
            .t4 => 16384,
            .a100 => 40960,
            .generic => 8192,
            .unknown => 8192,
        };
    }

    pub fn hasInt8TensorCores(self: NvidiaGpu) bool {
        return switch (self) {
            .t4, .a100, .generic => true,
            .unknown => false,
        };
    }
};

// ============================================================================
// CUDA Backend Configuration
// ============================================================================

pub const CudaBackend = struct {
    allocator: Allocator,
    gpu: NvidiaGpu,
    device_id: u32,
    config: T4Config,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) !Self {
        const gpu_info = try detectCudaGpu(allocator);
        
        var config = T4Config{};
        if (gpu_info.gpu == .t4) {
            config = T4Config.forModelSize(7.0);  // Default to 7B optimization
        }
        
        return Self{
            .allocator = allocator,
            .gpu = gpu_info.gpu,
            .device_id = gpu_info.device_id,
            .config = config,
        };
    }
    
    pub fn deinit(self: *Self) void {
        _ = self;
    }
    
    /// Configure for specific model size
    pub fn configureForModel(self: *Self, model_size_gb: f32) void {
        if (self.gpu == .t4) {
            self.config = T4Config.forModelSize(model_size_gb);
        }
    }
    
    /// Get optimal batch size for current configuration
    pub fn getOptimalBatchSize(self: *const Self) u32 {
        return self.config.max_batch_size;
    }
    
    /// Check if model fits in memory
    pub fn canFitModel(self: *const Self, model_size_mb: u32) bool {
        const available_mb = self.gpu.getMemoryMb() - self.config.kv_cache_size_mb - 1024;  // 1GB headroom
        return model_size_mb <= available_mb;
    }
    
    /// Get quantization recommendation
    pub fn shouldQuantize(self: *const Self, model_size_mb: u32) bool {
        // Recommend INT8 if model is more than 60% of memory
        const threshold = self.gpu.getMemoryMb() * 6 / 10;
        return model_size_mb > threshold;
    }
};

const CudaGpuInfo = struct {
    gpu: NvidiaGpu,
    device_id: u32,
    name: []const u8,
};

fn detectCudaGpu(allocator: Allocator) !CudaGpuInfo {
    // Run nvidia-smi to detect GPU
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "nvidia-smi",
            "--query-gpu=name,index",
            "--format=csv,noheader,nounits",
        },
        .max_output_bytes = 4096,
    }) catch {
        return CudaGpuInfo{
            .gpu = .unknown,
            .device_id = 0,
            .name = "unknown",
        };
    };
    
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    // Parse output: "Tesla T4, 0"
    var lines = std.mem.splitSequence(u8, result.stdout, "\n");
    if (lines.next()) |line| {
        var parts = std.mem.splitSequence(u8, line, ", ");
        const name = parts.next() orelse "unknown";
        const idx_str = parts.next() orelse "0";
        const device_id = std.fmt.parseInt(u32, idx_str, 10) catch 0;
        
        return CudaGpuInfo{
            .gpu = NvidiaGpu.fromName(name),
            .device_id = device_id,
            .name = try allocator.dupe(u8, name),
        };
    }
    
    return CudaGpuInfo{
        .gpu = .unknown,
        .device_id = 0,
        .name = "unknown",
    };
}

// ============================================================================
// Ollama T4 Configuration
// ============================================================================

pub const OllamaT4Config = struct {
    /// Generate Ollama environment variables for T4 optimization
    pub fn getEnvVars() []const struct { key: []const u8, value: []const u8 } {
        return &[_]struct { key: []const u8, value: []const u8 }{
            // GPU memory settings
            .{ .key = "OLLAMA_GPU_OVERHEAD", .value = "256000000" },  // 256MB overhead
            .{ .key = "OLLAMA_MAX_LOADED_MODELS", .value = "1" },
            
            // Flash attention (critical for T4)
            .{ .key = "OLLAMA_FLASH_ATTENTION", .value = "1" },
            
            // KV cache quantization
            .{ .key = "OLLAMA_KV_CACHE_TYPE", .value = "q8_0" },
            
            // Batch settings
            .{ .key = "OLLAMA_NUM_PARALLEL", .value = "4" },
            .{ .key = "OLLAMA_MAX_QUEUE", .value = "512" },
            
            // CUDA specific
            .{ .key = "CUDA_VISIBLE_DEVICES", .value = "0" },
        };
    }
    
    /// Generate modelfile parameters for T4
    pub fn getModelfileParams(model_size_gb: f32) []const u8 {
        if (model_size_gb <= 7.0) {
            return 
                \\PARAMETER num_ctx 4096
                \\PARAMETER num_batch 512
                \\PARAMETER num_gpu 99
                \\PARAMETER main_gpu 0
            ;
        } else if (model_size_gb <= 13.0) {
            return 
                \\PARAMETER num_ctx 2048
                \\PARAMETER num_batch 256
                \\PARAMETER num_gpu 99
                \\PARAMETER main_gpu 0
            ;
        } else {
            return 
                \\PARAMETER num_ctx 1024
                \\PARAMETER num_batch 128
                \\PARAMETER num_gpu 99
                \\PARAMETER main_gpu 0
            ;
        }
    }
};

// ============================================================================
// Mojo-RT Kernel FFI Bridge
// ============================================================================
//
// C-linkage bindings to compiled Mojo kernels.  Mojo compiles to native
// objects that export C-compatible symbols.  These externs are resolved
// at link time against the Mojo .o / .so artefacts.

// -- Fused RMSNorm + Scale + Int8 Quantization (fused_ops.mojo) --
extern fn fused_rmsnorm_quantize(
    output: [*]i8,
    input: [*]const f32,
    weight: [*]const f32,
    quant_scale: f32,
    batch_size: usize,
    hidden_dim: usize,
    eps: f32,
) void;

// -- Fused RMSNorm + Linear Projection (fused_ops.mojo) --
extern fn fused_rmsnorm_linear(
    output: [*]f32,
    input: [*]const f32,
    norm_weight: [*]const f32,
    proj_weight: [*]const f32,
    batch_size: usize,
    hidden_dim: usize,
    out_dim: usize,
    eps: f32,
) void;

// -- Fused QKV Projection + RoPE (fused_ops.mojo) --
extern fn fused_qkv_rope(
    q_out: [*]f32,
    k_out: [*]f32,
    v_out: [*]f32,
    x: [*]const f32,
    wq: [*]const f32,
    wk: [*]const f32,
    wv: [*]const f32,
    position: usize,
    hidden_dim: usize,
    num_heads: usize,
    num_kv_heads: usize,
    head_dim: usize,
    rope_theta: f32,
) void;

// -- Fused SwiGLU FFN (fused_ops.mojo) --
extern fn fused_swiglu_ffn(
    output: [*]f32,
    x: [*]const f32,
    w_gate: [*]const f32,
    w_up: [*]const f32,
    w_down: [*]const f32,
    hidden_dim: usize,
    ff_dim: usize,
) void;

// -- TOON Masked Sampler (toon_sampler.mojo) --
extern fn apply_toon_mask(
    logits: [*]f32,
    token_classes: [*]const u8,
    allowed_mask: u8,
    vocab_size: usize,
) void;

extern fn toon_sample_topk(
    logits: [*]f32,
    token_classes: [*]const u8,
    allowed_mask: u8,
    vocab_size: usize,
    top_k: usize,
    temperature: f32,
) usize;

extern fn build_vocab_class_table(
    class_table: [*]u8,
    vocab_tokens: [*]const u8,
    vocab_lengths: [*]const i32,
    vocab_size: usize,
    max_token_len: usize,
    eos_token_id: usize,
) void;

/// TOON token class bitfield constants (mirrors toon_sampler.mojo).
pub const ToonClass = struct {
    pub const ALPHA: u8 = 0x01;
    pub const NUMERIC: u8 = 0x02;
    pub const DELIMITER: u8 = 0x04;
    pub const WHITESPACE: u8 = 0x08;
    pub const BRACKET: u8 = 0x10;
    pub const SPECIAL: u8 = 0x20;
    pub const EOS: u8 = 0x40;
    pub const ALL: u8 = 0x7F;
};

/// Mojo-RT inference context — holds buffers and orchestrates fused kernel calls.
pub const MojoRTContext = struct {
    allocator: Allocator,
    config: T4Config,

    // Buffers
    q_buf: ?[*]f32 = null,
    k_buf: ?[*]f32 = null,
    v_buf: ?[*]f32 = null,
    norm_buf: ?[*]f32 = null,
    ffn_buf: ?[*]f32 = null,
    quant_buf: ?[*]i8 = null,
    logits_buf: ?[*]f32 = null,
    vocab_classes: ?[*]u8 = null,

    hidden_dim: u32 = 0,
    ff_dim: u32 = 0,
    num_heads: u32 = 0,
    num_kv_heads: u32 = 0,
    head_dim: u32 = 0,
    vocab_size: u32 = 0,

    const Self = @This();

    pub fn init(allocator: Allocator, config: T4Config) Self {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        const q_count: usize = @as(usize, self.num_heads) * @as(usize, self.head_dim);
        const kv_count: usize = @as(usize, self.num_kv_heads) * @as(usize, self.head_dim);
        const hidden_dim: usize = @as(usize, self.hidden_dim);
        const ff_dim: usize = @as(usize, self.ff_dim);
        const vocab_size: usize = @as(usize, self.vocab_size);

        if (self.q_buf) |p| self.allocator.free(@as([*]f32, @ptrCast(p))[0..q_count]);
        if (self.k_buf) |p| self.allocator.free(@as([*]f32, @ptrCast(p))[0..kv_count]);
        if (self.v_buf) |p| self.allocator.free(@as([*]f32, @ptrCast(p))[0..kv_count]);
        if (self.norm_buf) |p| self.allocator.free(@as([*]f32, @ptrCast(p))[0..hidden_dim]);
        if (self.ffn_buf) |p| self.allocator.free(@as([*]f32, @ptrCast(p))[0..ff_dim]);
        if (self.quant_buf) |p| self.allocator.free(@as([*]i8, @ptrCast(p))[0..hidden_dim]);
        if (self.logits_buf) |p| self.allocator.free(@as([*]f32, @ptrCast(p))[0..vocab_size]);
        if (self.vocab_classes) |p| self.allocator.free(@as([*]u8, @ptrCast(p))[0..vocab_size]);
    }

    /// Validate a MojoRTWeightMap before starting inference.
    /// Returns error.MissingTensor if any required pointer is null.
    /// Call this once after GGUFModelLoader.buildWeightMap() and before
    /// the first runFusedAttentionLayer / runFusedFFN call.
    pub fn validateWeightMap(
        _: *const Self,
        weight_map: *const @import("../llm/model_store.zig").MojoRTWeightMap,
    ) !void {
        try weight_map.validate();
    }

    /// Run a single Mojo-RT fused attention layer.
    pub fn runFusedAttentionLayer(
        self: *Self,
        hidden: [*]f32,
        attn_norm_w: [*]const f32,
        wq: [*]const f32,
        wk: [*]const f32,
        wv: [*]const f32,
        position: usize,
    ) void {
        fused_qkv_rope(
            self.q_buf.?,
            self.k_buf.?,
            self.v_buf.?,
            hidden,
            wq,
            wk,
            wv,
            position,
            self.hidden_dim,
            self.num_heads,
            self.num_kv_heads,
            self.head_dim,
            10000.0,
        );
        _ = attn_norm_w;
    }

    /// Run a fused FFN layer (SwiGLU).
    pub fn runFusedFFN(
        self: *Self,
        hidden: [*]f32,
        w_gate: [*]const f32,
        w_up: [*]const f32,
        w_down: [*]const f32,
    ) void {
        fused_swiglu_ffn(
            self.ffn_buf.?,
            hidden,
            w_gate,
            w_up,
            w_down,
            self.hidden_dim,
            self.ff_dim,
        );
    }

    /// Apply TOON mask and sample.
    pub fn sampleWithToonMask(
        self: *Self,
        logits: [*]f32,
        allowed_mask: u8,
        top_k: usize,
        temperature: f32,
    ) usize {
        return toon_sample_topk(
            logits,
            self.vocab_classes.?,
            allowed_mask,
            self.vocab_size,
            top_k,
            temperature,
        );
    }

    /// Fused RMSNorm + Int8 quantisation for Turing tensor core matmul.
    pub fn quantiseLayer(
        self: *Self,
        output: [*]i8,
        input: [*]const f32,
        norm_weight: [*]const f32,
        quant_scale: f32,
        batch_size: usize,
    ) void {
        fused_rmsnorm_quantize(
            output,
            input,
            norm_weight,
            quant_scale,
            batch_size,
            self.hidden_dim,
            1e-6,
        );
    }
};

// ============================================================================
// Tests
// ============================================================================

test "T4 detection" {
    const t4 = NvidiaGpu.fromName("Tesla T4");
    try std.testing.expectEqual(NvidiaGpu.t4, t4);
    try std.testing.expectEqual(@as(u32, 16384), t4.getMemoryMb());
    try std.testing.expect(t4.hasInt8TensorCores());
}

test "T4 config for model sizes" {
    const config_7b = T4Config.forModelSize(7.0);
    try std.testing.expectEqual(@as(u32, 8), config_7b.max_batch_size);
    try std.testing.expectEqual(@as(u32, 4096), config_7b.max_sequence_length);
    
    const config_13b = T4Config.forModelSize(13.0);
    try std.testing.expectEqual(@as(u32, 4), config_13b.max_batch_size);
    try std.testing.expect(config_13b.use_int8_quantization);
}
