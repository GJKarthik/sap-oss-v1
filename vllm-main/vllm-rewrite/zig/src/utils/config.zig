//! Configuration Management for vLLM
//!
//! Defines configuration structures and parsing for the vLLM engine.
//! Configurations can be loaded from files, environment variables, or CLI args.

const std = @import("std");

/// Engine configuration - controls overall engine behavior
pub const EngineConfig = struct {
    /// Path to the model (HuggingFace Hub ID or local path)
    model_path: []const u8,

    /// Number of GPUs for tensor parallelism
    tensor_parallel_size: u32 = 1,

    /// Number of GPUs for pipeline parallelism
    pipeline_parallel_size: u32 = 1,

    /// Maximum model context length (null = use model's default)
    max_model_len: ?u32 = null,

    /// GPU memory utilization fraction (0.0-1.0)
    gpu_memory_utilization: f32 = 0.9,

    /// Quantization method (awq, gptq, fp8, int8, etc.)
    quantization: ?[]const u8 = null,

    /// Data type for model weights
    dtype: DataType = .auto,

    /// Whether to trust remote code from HuggingFace
    trust_remote_code: bool = false,

    /// Download directory for models
    download_dir: ?[]const u8 = null,

    /// Revision/branch for HuggingFace models
    revision: ?[]const u8 = null,

    /// Whether to use the tokenizer from the model
    tokenizer_mode: TokenizerMode = .auto,

    /// Random seed for reproducibility
    seed: u64 = 0,

    const Self = @This();

    /// Validate the configuration
    pub fn validate(self: *const Self) !void {
        if (self.model_path.len == 0) {
            return error.EmptyModelPath;
        }

        if (self.tensor_parallel_size == 0) {
            return error.InvalidTensorParallelSize;
        }

        if (self.pipeline_parallel_size == 0) {
            return error.InvalidPipelineParallelSize;
        }

        if (self.gpu_memory_utilization <= 0 or self.gpu_memory_utilization > 1.0) {
            return error.InvalidGpuMemoryUtilization;
        }
    }

    /// Get total number of GPUs required
    pub fn totalGpus(self: *const Self) u32 {
        return self.tensor_parallel_size * self.pipeline_parallel_size;
    }
};

/// Data type for model weights
pub const DataType = enum {
    auto,
    float16,
    bfloat16,
    float32,

    pub fn toString(self: DataType) []const u8 {
        return switch (self) {
            .auto => "auto",
            .float16 => "float16",
            .bfloat16 => "bfloat16",
            .float32 => "float32",
        };
    }

    pub fn fromString(str: []const u8) DataType {
        if (std.mem.eql(u8, str, "float16") or std.mem.eql(u8, str, "fp16")) return .float16;
        if (std.mem.eql(u8, str, "bfloat16") or std.mem.eql(u8, str, "bf16")) return .bfloat16;
        if (std.mem.eql(u8, str, "float32") or std.mem.eql(u8, str, "fp32")) return .float32;
        return .auto;
    }
};

/// Tokenizer mode
pub const TokenizerMode = enum {
    auto,
    slow,
    mistral,

    pub fn fromString(str: []const u8) TokenizerMode {
        if (std.mem.eql(u8, str, "slow")) return .slow;
        if (std.mem.eql(u8, str, "mistral")) return .mistral;
        return .auto;
    }
};

/// Scheduler configuration
pub const SchedulerConfig = struct {
    /// Maximum number of sequences in a batch
    max_num_seqs: u32 = 256,

    /// Maximum number of concurrently running requests
    max_running_requests: u32 = 32,

    /// Maximum number of tokens per iteration
    max_num_batched_tokens: ?u32 = null,

    /// Maximum padding percentage for chunked prefill
    max_paddings: u32 = 256,

    /// Delay factor for scheduling
    delay_factor: f32 = 0.0,

    /// Whether to enable chunked prefill
    enable_chunked_prefill: bool = false,

    /// Preemption mode
    preemption_mode: PreemptionMode = .recompute,

    const Self = @This();

    pub fn validate(self: *const Self) !void {
        if (self.max_num_seqs == 0) {
            return error.InvalidMaxNumSeqs;
        }

        if (self.delay_factor < 0) {
            return error.InvalidDelayFactor;
        }
    }
};

/// Preemption mode for scheduler
pub const PreemptionMode = enum {
    /// Recompute KV cache when resuming
    recompute,
    /// Swap KV cache to CPU memory
    swap,

    pub fn fromString(str: []const u8) PreemptionMode {
        if (std.mem.eql(u8, str, "swap")) return .swap;
        return .recompute;
    }
};

/// Cache configuration for KV cache
pub const CacheConfig = struct {
    /// Block size for paged attention
    block_size: u32 = 16,

    /// Number of GPU blocks (0 = auto)
    num_gpu_blocks: u32 = 0,

    /// Number of CPU blocks for swapping
    num_cpu_blocks: u32 = 0,

    /// Whether to enable prefix caching
    enable_prefix_caching: bool = false,

    /// Cache data type
    cache_dtype: CacheDType = .auto,

    const Self = @This();

    pub fn validate(self: *const Self) !void {
        if (self.block_size == 0) {
            return error.InvalidBlockSize;
        }

        // Block size should be a power of 2
        if (self.block_size & (self.block_size - 1) != 0) {
            return error.BlockSizeNotPowerOf2;
        }
    }
};

/// Cache data type
pub const CacheDType = enum {
    auto,
    fp8,
    fp8_e5m2,
    fp8_e4m3,

    pub fn fromString(str: []const u8) CacheDType {
        if (std.mem.eql(u8, str, "fp8")) return .fp8;
        if (std.mem.eql(u8, str, "fp8_e5m2")) return .fp8_e5m2;
        if (std.mem.eql(u8, str, "fp8_e4m3")) return .fp8_e4m3;
        return .auto;
    }
};

/// LoRA configuration
pub const LoRAConfig = struct {
    /// Whether LoRA is enabled
    enable_lora: bool = false,

    /// Maximum number of LoRA adapters
    max_loras: u32 = 1,

    /// Maximum LoRA rank
    max_lora_rank: u32 = 16,

    /// Path to LoRA weights
    lora_path: ?[]const u8 = null,

    /// LoRA extra vocabulary size
    lora_extra_vocab_size: u32 = 256,

    const Self = @This();

    pub fn validate(self: *const Self) !void {
        if (self.enable_lora) {
            if (self.max_loras == 0) {
                return error.InvalidMaxLoras;
            }

            if (self.max_lora_rank == 0) {
                return error.InvalidMaxLoraRank;
            }
        }
    }
};

/// Server configuration for HTTP/gRPC servers
pub const ServerConfig = struct {
    /// Host to bind to
    host: []const u8 = "0.0.0.0",

    /// Port to listen on
    port: u16 = 8000,

    /// gRPC port (0 = disabled)
    grpc_port: u16 = 0,

    /// Maximum concurrent requests
    max_concurrent_requests: u32 = 1000,

    /// Request timeout in seconds
    timeout_seconds: u32 = 600,

    /// Whether to enable CORS
    enable_cors: bool = true,

    /// API key for authentication (null = disabled)
    api_key: ?[]const u8 = null,

    /// SSL certificate path
    ssl_certfile: ?[]const u8 = null,

    /// SSL key path
    ssl_keyfile: ?[]const u8 = null,

    const Self = @This();

    pub fn validate(self: *const Self) !void {
        if (self.port == 0) {
            return error.InvalidPort;
        }

        if (self.max_concurrent_requests == 0) {
            return error.InvalidMaxConcurrentRequests;
        }

        // If SSL cert is provided, key must also be provided
        if ((self.ssl_certfile != null) != (self.ssl_keyfile != null)) {
            return error.IncompleteSSLConfig;
        }
    }
};

/// Combined configuration
pub const VllmConfig = struct {
    engine: EngineConfig,
    scheduler: SchedulerConfig = .{},
    cache: CacheConfig = .{},
    lora: LoRAConfig = .{},
    server: ServerConfig = .{},

    const Self = @This();

    /// Validate all configurations
    pub fn validate(self: *const Self) !void {
        try self.engine.validate();
        try self.scheduler.validate();
        try self.cache.validate();
        try self.lora.validate();
        try self.server.validate();
    }
};

/// Load configuration from environment variables
pub fn loadFromEnv(allocator: std.mem.Allocator) !VllmConfig {
    _ = allocator;

    // Get model path from environment
    const model_path = std.posix.getenv("VLLM_MODEL") orelse "";

    var config = VllmConfig{
        .engine = .{
            .model_path = model_path,
        },
    };

    // Parse tensor parallel size
    if (std.posix.getenv("VLLM_TENSOR_PARALLEL_SIZE")) |tp_str| {
        config.engine.tensor_parallel_size = std.fmt.parseInt(u32, tp_str, 10) catch 1;
    }

    // Parse GPU memory utilization
    if (std.posix.getenv("VLLM_GPU_MEMORY_UTILIZATION")) |mem_str| {
        config.engine.gpu_memory_utilization = std.fmt.parseFloat(f32, mem_str) catch 0.9;
    }

    // Parse port
    if (std.posix.getenv("VLLM_PORT")) |port_str| {
        config.server.port = std.fmt.parseInt(u16, port_str, 10) catch 8000;
    }

    return config;
}

// ============================================
// Tests
// ============================================

test "EngineConfig validation" {
    var config = EngineConfig{
        .model_path = "meta-llama/Llama-3-8B",
    };

    try config.validate();

    config.model_path = "";
    try std.testing.expectError(error.EmptyModelPath, config.validate());
}

test "EngineConfig totalGpus" {
    const config = EngineConfig{
        .model_path = "test",
        .tensor_parallel_size = 4,
        .pipeline_parallel_size = 2,
    };

    try std.testing.expectEqual(@as(u32, 8), config.totalGpus());
}

test "DataType fromString" {
    try std.testing.expectEqual(DataType.float16, DataType.fromString("float16"));
    try std.testing.expectEqual(DataType.float16, DataType.fromString("fp16"));
    try std.testing.expectEqual(DataType.bfloat16, DataType.fromString("bfloat16"));
    try std.testing.expectEqual(DataType.auto, DataType.fromString("unknown"));
}

test "CacheConfig validation" {
    var config = CacheConfig{};
    try config.validate();

    config.block_size = 15; // Not power of 2
    try std.testing.expectError(error.BlockSizeNotPowerOf2, config.validate());
}

test "ServerConfig validation" {
    var config = ServerConfig{};
    try config.validate();

    config.ssl_certfile = "/path/to/cert";
    config.ssl_keyfile = null;
    try std.testing.expectError(error.IncompleteSSLConfig, config.validate());
}