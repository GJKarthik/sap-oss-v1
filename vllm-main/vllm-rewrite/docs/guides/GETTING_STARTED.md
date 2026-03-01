# Getting Started with vLLM Zig
## Installation and Quick Start Guide

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Installation](#installation)
3. [Quick Start](#quick-start)
4. [Configuration](#configuration)
5. [Running Your First Inference](#running-your-first-inference)
6. [Server Mode](#server-mode)
7. [Best Practices](#best-practices)
8. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### System Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | 8 cores | 16+ cores |
| RAM | 16 GB | 64+ GB |
| GPU | NVIDIA 16GB | NVIDIA 80GB |
| Disk | 100 GB SSD | 500 GB NVMe |
| OS | Linux/macOS | Linux (Ubuntu 22.04) |

### Software Requirements

```bash
# Zig compiler (0.11.0 or later)
zig version  # Should be >= 0.11.0

# CUDA toolkit (for GPU support)
nvcc --version  # Should be >= 11.8

# Git for cloning
git --version
```

### Supported GPUs

| GPU Family | Models | Memory |
|------------|--------|--------|
| NVIDIA A100 | A100-40GB, A100-80GB | 40-80 GB |
| NVIDIA H100 | H100-80GB | 80 GB |
| NVIDIA RTX | 3090, 4090 | 24 GB |
| NVIDIA L40 | L40, L40S | 48 GB |

---

## Installation

### Option 1: Build from Source

```bash
# Clone the repository
git clone https://github.com/vllm-project/vllm-zig.git
cd vllm-zig

# Build the project
zig build -Doptimize=ReleaseFast

# Verify installation
./zig-out/bin/vllm --version
```

### Option 2: Using Package Manager

```bash
# Using Zig package manager
# Add to build.zig.zon:
.dependencies = .{
    .vllm = .{
        .url = "https://github.com/vllm-project/vllm-zig/archive/v1.0.0.tar.gz",
        .hash = "...",
    },
},
```

### Build Options

| Option | Description | Default |
|--------|-------------|---------|
| `-Doptimize=Debug` | Debug build | N/A |
| `-Doptimize=ReleaseFast` | Optimized build | Recommended |
| `-Dcuda=true` | Enable CUDA support | true |
| `-Davx512=true` | Enable AVX-512 | auto |

---

## Quick Start

### 5-Minute Setup

```zig
const std = @import("std");
const vllm = @import("vllm");

pub fn main() !void {
    // 1. Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 2. Create engine with default config
    var engine = try vllm.LLMEngine.init(allocator, .{
        .model_path = "models/llama-7b",
    });
    defer engine.deinit();

    // 3. Submit a request
    _ = try engine.submitRequest(.{
        .request_id = "hello-world",
        .prompt_tokens = &[_]u32{ 1, 15043, 29892, 825, 338, 278, 3855, 310, 9556, 29973 },
        .max_new_tokens = 50,
    });

    // 4. Process until done
    while (engine.hasPendingWork()) {
        const result = try engine.step();
        if (result.completed_requests.len > 0) {
            std.debug.print("Generation complete!\n", .{});
        }
    }
}
```

---

## Configuration

### Engine Configuration

```zig
const config = vllm.EngineConfig{
    // Model settings
    .model_path = "models/llama-7b",
    .dtype = .float16,
    
    // Performance settings
    .max_batch_size = 32,
    .max_seq_len = 4096,
    
    // GPU settings
    .device_id = 0,
    .tensor_parallel_size = 1,
    
    // Memory settings
    .gpu_memory_utilization = 0.9,
    .kv_cache_config = .{
        .block_size = 16,
        .enable_prefix_caching = true,
    },
};
```

### Sampling Configuration

```zig
const sampling = vllm.SamplingParams{
    // Temperature controls randomness
    .temperature = 0.7,
    
    // Top-p (nucleus) sampling
    .top_p = 0.9,
    
    // Top-k sampling (0 = disabled)
    .top_k = 50,
    
    // Penalties
    .repetition_penalty = 1.1,
    .frequency_penalty = 0.0,
    .presence_penalty = 0.0,
    
    // Reproducibility
    .seed = 42,
};
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `VLLM_GPU_MEMORY_FRACTION` | GPU memory usage | 0.9 |
| `VLLM_LOG_LEVEL` | Logging verbosity | info |
| `VLLM_NUM_WORKERS` | Worker threads | auto |
| `CUDA_VISIBLE_DEVICES` | GPU selection | all |

---

## Running Your First Inference

### Basic Text Generation

```zig
const std = @import("std");
const vllm = @import("vllm");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize engine
    var engine = try vllm.LLMEngine.init(allocator, .{
        .model_path = "meta-llama/Llama-2-7b-hf",
        .max_batch_size = 8,
    });
    defer engine.deinit();

    // Create request with custom sampling
    const request_id = try engine.submitRequest(.{
        .request_id = "gen-001",
        .prompt_tokens = try tokenize(allocator, "The future of AI is"),
        .max_new_tokens = 100,
        .sampling_params = .{
            .temperature = 0.8,
            .top_p = 0.95,
        },
    });

    // Wait for completion
    while (engine.hasPendingWork()) {
        _ = try engine.step();
    }

    // Get result
    if (engine.getResult(request_id)) |result| {
        const text = try detokenize(allocator, result.output_tokens);
        std.debug.print("Generated: {s}\n", .{text});
    }
}
```

### Batch Processing

```zig
// Submit multiple requests
const prompts = [_][]const u8{
    "What is machine learning?",
    "Explain quantum computing.",
    "How does DNA work?",
};

for (prompts, 0..) |prompt, i| {
    _ = try engine.submitRequest(.{
        .request_id = try std.fmt.allocPrint(allocator, "batch-{d}", .{i}),
        .prompt_tokens = try tokenize(allocator, prompt),
        .max_new_tokens = 50,
    });
}

// Process all requests
while (engine.hasPendingWork()) {
    _ = try engine.step();
}
```

### Streaming Output

```zig
const request_id = try engine.submitRequest(.{
    .request_id = "stream-001",
    .prompt_tokens = prompt_tokens,
    .max_new_tokens = 100,
    .stream = true,
});

// Process with streaming callback
while (engine.hasPendingWork()) {
    const result = try engine.step();
    
    for (result.streaming_outputs) |output| {
        // Print each token as it's generated
        std.debug.print("{s}", .{output.token_text});
    }
}
```

---

## Server Mode

### Starting the Server

```zig
const vllm = @import("vllm");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try vllm.OpenAIServer.init(allocator, .{
        .host = "0.0.0.0",
        .port = 8000,
        .model_path = "meta-llama/Llama-2-7b-hf",
        .max_concurrent = 100,
    });
    defer server.deinit();

    std.debug.print("Server starting on http://0.0.0.0:8000\n", .{});
    try server.serve();
}
```

### Using the API

```bash
# Chat completion
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-2-7b",
    "messages": [
      {"role": "user", "content": "Hello!"}
    ],
    "max_tokens": 100
  }'

# Text completion
curl http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-2-7b",
    "prompt": "The meaning of life is",
    "max_tokens": 50
  }'

# List models
curl http://localhost:8000/v1/models
```

---

## Best Practices

### Memory Management

```zig
// Use arena allocator for request-scoped allocations
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const request_allocator = arena.allocator();

// Process request with arena
try processRequest(request_allocator, request);
// All memory freed automatically
```

### Error Handling

```zig
const result = engine.submitRequest(request) catch |err| switch (err) {
    error.OutOfMemory => {
        std.log.err("Not enough memory for request", .{});
        return;
    },
    error.CacheFull => {
        std.log.warn("Cache full, waiting...", .{});
        std.time.sleep(100_000_000);
        continue;
    },
    else => return err,
};
```

### Performance Optimization

1. **Use appropriate batch sizes**
   ```zig
   .max_batch_size = 32,  // Balance throughput vs latency
   ```

2. **Enable prefix caching**
   ```zig
   .enable_prefix_caching = true,  // Reuse common prefixes
   ```

3. **Set memory utilization**
   ```zig
   .gpu_memory_utilization = 0.9,  // Use 90% of GPU memory
   ```

---

## Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| Out of Memory | Model too large | Reduce batch size, use quantization |
| Slow inference | GPU not detected | Check CUDA installation |
| Model not found | Wrong path | Verify model path exists |
| High latency | Small batches | Increase batch size |

### Debugging

```zig
// Enable debug logging
const config = vllm.EngineConfig{
    .log_level = .debug,
    // ...
};

// Check GPU status
const gpu_info = try vllm.getGPUInfo();
std.debug.print("GPU: {s}, Memory: {d}GB\n", .{
    gpu_info.name,
    gpu_info.memory_gb,
});
```

### Getting Help

- Documentation: https://docs.vllm-zig.io
- Issues: https://github.com/vllm-project/vllm-zig/issues
- Discord: https://discord.gg/vllm

---

*Getting Started Guide v1.0 - vLLM Zig Rewrite*