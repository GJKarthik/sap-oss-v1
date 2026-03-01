# vLLM Zig API Reference
## Complete API Documentation

---

## Table of Contents

1. [Core Engine API](#core-engine-api)
2. [Attention API](#attention-api)
3. [Sampling API](#sampling-api)
4. [KV Cache API](#kv-cache-api)
5. [Batching API](#batching-api)
6. [Model API](#model-api)
7. [Quantization API](#quantization-api)
8. [Serving API](#serving-api)

---

## Core Engine API

### LLMEngine

The main entry point for LLM inference.

```zig
pub const LLMEngine = struct {
    /// Initialize a new LLM engine
    pub fn init(allocator: Allocator, config: EngineConfig) !LLMEngine;
    
    /// Clean up resources
    pub fn deinit(self: *LLMEngine) void;
    
    /// Submit a request for processing
    pub fn submitRequest(self: *LLMEngine, request: InferenceRequest) !RequestId;
    
    /// Get results for a completed request
    pub fn getResult(self: *LLMEngine, id: RequestId) ?InferenceResult;
    
    /// Run a single inference step
    pub fn step(self: *LLMEngine) !StepResult;
    
    /// Check if engine has pending work
    pub fn hasPendingWork(self: *const LLMEngine) bool;
};
```

### EngineConfig

Configuration for the LLM engine.

```zig
pub const EngineConfig = struct {
    /// Model path or identifier
    model_path: []const u8,
    
    /// Maximum sequence length
    max_seq_len: usize = 2048,
    
    /// Maximum batch size
    max_batch_size: usize = 32,
    
    /// GPU device ID (null for CPU)
    device_id: ?u32 = null,
    
    /// Enable tensor parallelism
    tensor_parallel_size: usize = 1,
    
    /// KV cache configuration
    kv_cache_config: KVCacheConfig = .{},
    
    /// Sampling configuration
    sampling_config: SamplingConfig = .{},
};
```

### InferenceRequest

A request for text generation.

```zig
pub const InferenceRequest = struct {
    /// Unique request identifier
    request_id: []const u8,
    
    /// Input prompt (token IDs)
    prompt_tokens: []const u32,
    
    /// Maximum tokens to generate
    max_new_tokens: usize = 100,
    
    /// Sampling parameters
    sampling_params: SamplingParams = .{},
    
    /// Whether to stream output
    stream: bool = false,
    
    /// Stop sequences
    stop_sequences: []const []const u32 = &.{},
};
```

---

## Attention API

### PagedAttention

Efficient paged attention implementation.

```zig
pub const PagedAttention = struct {
    /// Initialize paged attention
    pub fn init(
        allocator: Allocator,
        num_heads: usize,
        head_dim: usize,
        num_kv_heads: usize,
    ) !PagedAttention;
    
    /// Compute attention with paged KV cache
    pub fn forward(
        self: *PagedAttention,
        query: []const f16,
        key_cache: []const []const f16,
        value_cache: []const []const f16,
        block_tables: []const usize,
        seq_lens: []const usize,
    ) ![]f16;
    
    /// Prefill phase attention
    pub fn prefill(
        self: *PagedAttention,
        query: []const f16,
        key: []const f16,
        value: []const f16,
    ) ![]f16;
};
```

### FlashAttention

Optimized flash attention for long sequences.

```zig
pub const FlashAttention = struct {
    /// Initialize flash attention
    pub fn init(config: FlashAttentionConfig) FlashAttention;
    
    /// Forward pass with flash attention
    pub fn forward(
        self: *FlashAttention,
        q: Tensor,
        k: Tensor,
        v: Tensor,
        causal_mask: bool,
    ) !Tensor;
};

pub const FlashAttentionConfig = struct {
    head_dim: usize,
    num_heads: usize,
    softmax_scale: ?f32 = null,
    dropout_p: f32 = 0.0,
};
```

---

## Sampling API

### Sampler

Token sampling from logits.

```zig
pub const Sampler = struct {
    /// Initialize sampler
    pub fn init(allocator: Allocator, vocab_size: usize) !Sampler;
    
    /// Sample a token from logits
    pub fn sample(
        self: *Sampler,
        logits: []const f32,
        params: SamplingParams,
    ) !u32;
    
    /// Sample tokens for a batch
    pub fn sampleBatch(
        self: *Sampler,
        logits_batch: []const []const f32,
        params_batch: []const SamplingParams,
    ) ![]u32;
};
```

### SamplingParams

Parameters controlling token sampling.

```zig
pub const SamplingParams = struct {
    /// Temperature for softmax
    temperature: f32 = 1.0,
    
    /// Top-p (nucleus) sampling
    top_p: f32 = 1.0,
    
    /// Top-k sampling
    top_k: usize = 0,
    
    /// Repetition penalty
    repetition_penalty: f32 = 1.0,
    
    /// Frequency penalty
    frequency_penalty: f32 = 0.0,
    
    /// Presence penalty
    presence_penalty: f32 = 0.0,
    
    /// Random seed (null for random)
    seed: ?u64 = null,
    
    /// Log probabilities to return
    logprobs: ?usize = null,
};
```

---

## KV Cache API

### KVCacheManager

Manages KV cache memory.

```zig
pub const KVCacheManager = struct {
    /// Initialize cache manager
    pub fn init(allocator: Allocator, config: KVCacheConfig) !KVCacheManager;
    
    /// Allocate blocks for a sequence
    pub fn allocateBlocks(self: *KVCacheManager, num_blocks: usize) ![]BlockId;
    
    /// Free blocks
    pub fn freeBlocks(self: *KVCacheManager, blocks: []const BlockId) void;
    
    /// Get cache utilization
    pub fn getUtilization(self: *const KVCacheManager) f32;
    
    /// Enable prefix caching
    pub fn enablePrefixCaching(self: *KVCacheManager) void;
    
    /// Find cached prefix
    pub fn findPrefix(self: *KVCacheManager, tokens: []const u32) ?PrefixMatch;
};

pub const KVCacheConfig = struct {
    /// Block size in tokens
    block_size: usize = 16,
    
    /// Total GPU memory for cache (bytes)
    gpu_memory_utilization: f32 = 0.9,
    
    /// Enable automatic eviction
    enable_eviction: bool = true,
    
    /// Enable prefix caching
    enable_prefix_caching: bool = true,
};
```

---

## Batching API

### ContinuousBatcher

Continuous batching scheduler.

```zig
pub const ContinuousBatcher = struct {
    /// Initialize batcher
    pub fn init(allocator: Allocator, config: BatchConfig) !ContinuousBatcher;
    
    /// Add request to waiting queue
    pub fn addRequest(self: *ContinuousBatcher, request: InferenceRequest) !void;
    
    /// Get next batch to process
    pub fn getNextBatch(self: *ContinuousBatcher) !?ScheduledBatch;
    
    /// Mark request as complete
    pub fn completeRequest(self: *ContinuousBatcher, request_id: []const u8) void;
    
    /// Get queue statistics
    pub fn getStats(self: *const ContinuousBatcher) BatchStats;
};

pub const BatchConfig = struct {
    /// Maximum batch size
    max_batch_size: usize = 32,
    
    /// Maximum tokens per batch
    max_tokens_per_batch: usize = 4096,
    
    /// Scheduling policy
    scheduling_policy: SchedulingPolicy = .fcfs,
    
    /// Preemption mode
    preemption_mode: PreemptionMode = .recompute,
};
```

---

## Model API

### ModelLoader

Load and manage models.

```zig
pub const ModelLoader = struct {
    /// Load a model from path
    pub fn load(allocator: Allocator, path: []const u8) !Model;
    
    /// Load with specific dtype
    pub fn loadWithDtype(
        allocator: Allocator,
        path: []const u8,
        dtype: DType,
    ) !Model;
    
    /// Load quantized model
    pub fn loadQuantized(
        allocator: Allocator,
        path: []const u8,
        quant_config: QuantConfig,
    ) !Model;
};
```

### Model

Base model interface.

```zig
pub const Model = struct {
    /// Run forward pass
    pub fn forward(self: *Model, input: ModelInput) !ModelOutput;
    
    /// Get model configuration
    pub fn getConfig(self: *const Model) ModelConfig;
    
    /// Get vocabulary size
    pub fn getVocabSize(self: *const Model) usize;
    
    /// Get hidden size
    pub fn getHiddenSize(self: *const Model) usize;
    
    /// Get number of layers
    pub fn getNumLayers(self: *const Model) usize;
};
```

---

## Quantization API

### AWQQuantizer

AWQ quantization support.

```zig
pub const AWQQuantizer = struct {
    /// Initialize quantizer
    pub fn init(config: AWQConfig) AWQQuantizer;
    
    /// Quantize weights
    pub fn quantize(self: *AWQQuantizer, weights: Tensor) !QuantizedTensor;
    
    /// Dequantize for computation
    pub fn dequantize(self: *AWQQuantizer, qweights: QuantizedTensor) !Tensor;
};

pub const AWQConfig = struct {
    /// Bit width (4 or 8)
    bits: u8 = 4,
    
    /// Group size for quantization
    group_size: usize = 128,
    
    /// Zero point handling
    zero_point: bool = true,
};
```

### GPTQQuantizer

GPTQ quantization support.

```zig
pub const GPTQQuantizer = struct {
    /// Initialize GPTQ quantizer
    pub fn init(config: GPTQConfig) GPTQQuantizer;
    
    /// Apply GPTQ quantization
    pub fn quantize(
        self: *GPTQQuantizer,
        weights: Tensor,
        hessian: Tensor,
    ) !QuantizedTensor;
};

pub const GPTQConfig = struct {
    bits: u8 = 4,
    group_size: usize = 128,
    act_order: bool = true,
    true_sequential: bool = true,
};
```

---

## Serving API

### OpenAIServer

OpenAI-compatible API server.

```zig
pub const OpenAIServer = struct {
    /// Initialize server
    pub fn init(allocator: Allocator, config: ServerConfig) !OpenAIServer;
    
    /// Start serving
    pub fn serve(self: *OpenAIServer) !void;
    
    /// Stop server
    pub fn stop(self: *OpenAIServer) void;
    
    /// Get server metrics
    pub fn getMetrics(self: *const OpenAIServer) ServerMetrics;
};

pub const ServerConfig = struct {
    /// Host to bind
    host: []const u8 = "0.0.0.0",
    
    /// Port to listen on
    port: u16 = 8000,
    
    /// Maximum concurrent requests
    max_concurrent: usize = 100,
    
    /// Request timeout (ms)
    timeout_ms: u64 = 30000,
    
    /// Enable CORS
    enable_cors: bool = true,
};
```

---

## Error Handling

### Common Errors

```zig
pub const VLLMError = error{
    /// Out of memory
    OutOfMemory,
    
    /// Invalid configuration
    InvalidConfig,
    
    /// Model loading failed
    ModelLoadError,
    
    /// Inference failed
    InferenceError,
    
    /// Request timeout
    Timeout,
    
    /// Cache full
    CacheFull,
    
    /// Invalid input
    InvalidInput,
    
    /// Device error
    DeviceError,
};
```

---

## Usage Examples

### Basic Inference

```zig
const std = @import("std");
const vllm = @import("vllm");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Initialize engine
    var engine = try vllm.LLMEngine.init(allocator, .{
        .model_path = "models/llama-7b",
        .max_batch_size = 8,
    });
    defer engine.deinit();
    
    // Submit request
    const request_id = try engine.submitRequest(.{
        .request_id = "req-001",
        .prompt_tokens = &[_]u32{ 1, 2, 3 },
        .max_new_tokens = 100,
    });
    
    // Process until complete
    while (engine.hasPendingWork()) {
        _ = try engine.step();
    }
    
    // Get result
    if (engine.getResult(request_id)) |result| {
        std.debug.print("Generated: {any}\n", .{result.output_tokens});
    }
}
```

### Server Mode

```zig
const vllm = @import("vllm");

pub fn main() !void {
    var server = try vllm.OpenAIServer.init(allocator, .{
        .port = 8000,
        .max_concurrent = 100,
    });
    defer server.deinit();
    
    try server.serve();
}
```

---

*API Reference v1.0 - vLLM Zig Rewrite*