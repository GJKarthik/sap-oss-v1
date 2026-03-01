# vLLM Zig Code Examples
## Complete Working Examples

---

## Table of Contents

1. [Basic Inference](#basic-inference)
2. [Batch Processing](#batch-processing)
3. [Streaming Output](#streaming-output)
4. [Chat Completions](#chat-completions)
5. [Quantized Models](#quantized-models)
6. [Multi-GPU Inference](#multi-gpu-inference)
7. [Custom Sampling](#custom-sampling)
8. [Structured Output](#structured-output)
9. [Server Deployment](#server-deployment)
10. [Advanced Patterns](#advanced-patterns)

---

## Basic Inference

### Simple Text Generation

```zig
const std = @import("std");
const vllm = @import("vllm");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize the LLM engine
    var engine = try vllm.LLMEngine.init(allocator, .{
        .model_path = "meta-llama/Llama-2-7b-hf",
        .max_batch_size = 8,
        .max_seq_len = 2048,
    });
    defer engine.deinit();

    // Tokenize the prompt
    const prompt = "The capital of France is";
    const prompt_tokens = try engine.tokenize(allocator, prompt);
    defer allocator.free(prompt_tokens);

    // Submit inference request
    const request_id = try engine.submitRequest(.{
        .request_id = "example-001",
        .prompt_tokens = prompt_tokens,
        .max_new_tokens = 20,
        .sampling_params = .{
            .temperature = 0.7,
            .top_p = 0.9,
        },
    });

    // Process until completion
    while (engine.hasPendingWork()) {
        _ = try engine.step();
    }

    // Retrieve and print result
    if (engine.getResult(request_id)) |result| {
        const output_text = try engine.detokenize(allocator, result.output_tokens);
        defer allocator.free(output_text);
        std.debug.print("Input: {s}\n", .{prompt});
        std.debug.print("Output: {s}\n", .{output_text});
    }
}
```

---

## Batch Processing

### Processing Multiple Prompts

```zig
const std = @import("std");
const vllm = @import("vllm");

pub fn batchInference(allocator: std.mem.Allocator) !void {
    var engine = try vllm.LLMEngine.init(allocator, .{
        .model_path = "meta-llama/Llama-2-7b-hf",
        .max_batch_size = 16,
    });
    defer engine.deinit();

    const prompts = [_][]const u8{
        "What is machine learning?",
        "Explain quantum computing in simple terms.",
        "How does photosynthesis work?",
        "What is the theory of relativity?",
        "Describe the water cycle.",
    };

    // Submit all requests
    var request_ids = std.ArrayList([]const u8).init(allocator);
    defer request_ids.deinit();

    for (prompts, 0..) |prompt, i| {
        const tokens = try engine.tokenize(allocator, prompt);
        const id = try std.fmt.allocPrint(allocator, "batch-{d}", .{i});
        
        _ = try engine.submitRequest(.{
            .request_id = id,
            .prompt_tokens = tokens,
            .max_new_tokens = 100,
        });
        
        try request_ids.append(id);
    }

    // Process all requests
    while (engine.hasPendingWork()) {
        const step_result = try engine.step();
        
        // Print completed requests
        for (step_result.completed_requests) |req_id| {
            if (engine.getResult(req_id)) |result| {
                const text = try engine.detokenize(allocator, result.output_tokens);
                std.debug.print("Completed {s}: {s}\n", .{ req_id, text });
            }
        }
    }
}
```

---

## Streaming Output

### Token-by-Token Streaming

```zig
const std = @import("std");
const vllm = @import("vllm");

pub fn streamingExample(allocator: std.mem.Allocator) !void {
    var engine = try vllm.LLMEngine.init(allocator, .{
        .model_path = "meta-llama/Llama-2-7b-hf",
    });
    defer engine.deinit();

    const prompt = "Once upon a time, in a magical forest,";
    const prompt_tokens = try engine.tokenize(allocator, prompt);

    _ = try engine.submitRequest(.{
        .request_id = "stream-001",
        .prompt_tokens = prompt_tokens,
        .max_new_tokens = 200,
        .stream = true,
        .sampling_params = .{
            .temperature = 0.8,
        },
    });

    std.debug.print("{s}", .{prompt});

    // Stream tokens as they're generated
    while (engine.hasPendingWork()) {
        const step_result = try engine.step();
        
        for (step_result.streaming_outputs) |output| {
            if (output.token_text) |text| {
                std.debug.print("{s}", .{text});
            }
        }
    }
    
    std.debug.print("\n", .{});
}
```

---

## Chat Completions

### Multi-Turn Conversation

```zig
const std = @import("std");
const vllm = @import("vllm");

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub fn chatExample(allocator: std.mem.Allocator) !void {
    var engine = try vllm.LLMEngine.init(allocator, .{
        .model_path = "meta-llama/Llama-2-7b-chat-hf",
    });
    defer engine.deinit();

    const messages = [_]ChatMessage{
        .{ .role = "system", .content = "You are a helpful assistant." },
        .{ .role = "user", .content = "What is the capital of Japan?" },
    };

    // Format messages into chat template
    const formatted = try formatChatMessages(allocator, &messages);
    defer allocator.free(formatted);
    
    const tokens = try engine.tokenize(allocator, formatted);

    _ = try engine.submitRequest(.{
        .request_id = "chat-001",
        .prompt_tokens = tokens,
        .max_new_tokens = 100,
        .sampling_params = .{
            .temperature = 0.7,
            .top_p = 0.9,
        },
    });

    while (engine.hasPendingWork()) {
        _ = try engine.step();
    }

    if (engine.getResult("chat-001")) |result| {
        const response = try engine.detokenize(allocator, result.output_tokens);
        std.debug.print("Assistant: {s}\n", .{response});
    }
}

fn formatChatMessages(allocator: std.mem.Allocator, messages: []const ChatMessage) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    const writer = result.writer();
    
    for (messages) |msg| {
        try writer.print("<|{s}|>\n{s}\n", .{ msg.role, msg.content });
    }
    try writer.writeAll("<|assistant|>\n");
    
    return result.toOwnedSlice();
}
```

---

## Quantized Models

### AWQ Quantization

```zig
const std = @import("std");
const vllm = @import("vllm");

pub fn awqExample(allocator: std.mem.Allocator) !void {
    var engine = try vllm.LLMEngine.init(allocator, .{
        .model_path = "TheBloke/Llama-2-7B-AWQ",
        .quantization = .{
            .method = .awq,
            .bits = 4,
            .group_size = 128,
        },
    });
    defer engine.deinit();

    // AWQ models use ~75% less memory
    std.debug.print("Memory usage: {d}MB\n", .{engine.getMemoryUsage() / 1024 / 1024});

    const prompt_tokens = try engine.tokenize(allocator, "Explain quantum entanglement:");
    
    _ = try engine.submitRequest(.{
        .request_id = "awq-001",
        .prompt_tokens = prompt_tokens,
        .max_new_tokens = 100,
    });

    while (engine.hasPendingWork()) {
        _ = try engine.step();
    }

    if (engine.getResult("awq-001")) |result| {
        const text = try engine.detokenize(allocator, result.output_tokens);
        std.debug.print("Response: {s}\n", .{text});
    }
}
```

### GPTQ Quantization

```zig
pub fn gptqExample(allocator: std.mem.Allocator) !void {
    var engine = try vllm.LLMEngine.init(allocator, .{
        .model_path = "TheBloke/Llama-2-7B-GPTQ",
        .quantization = .{
            .method = .gptq,
            .bits = 4,
            .group_size = 128,
            .act_order = true,
        },
    });
    defer engine.deinit();

    // Use engine as normal
    // ...
}
```

---

## Multi-GPU Inference

### Tensor Parallelism

```zig
const std = @import("std");
const vllm = @import("vllm");

pub fn multiGPUExample(allocator: std.mem.Allocator) !void {
    // Use 4 GPUs with tensor parallelism
    var engine = try vllm.LLMEngine.init(allocator, .{
        .model_path = "meta-llama/Llama-2-70b-hf",
        .tensor_parallel_size = 4,
        .device_ids = &[_]u32{ 0, 1, 2, 3 },
    });
    defer engine.deinit();

    std.debug.print("Running on {d} GPUs\n", .{engine.getNumDevices()});

    const prompt = "Write a detailed essay about climate change:";
    const tokens = try engine.tokenize(allocator, prompt);

    _ = try engine.submitRequest(.{
        .request_id = "multi-gpu-001",
        .prompt_tokens = tokens,
        .max_new_tokens = 500,
    });

    while (engine.hasPendingWork()) {
        _ = try engine.step();
    }
}
```

### Pipeline Parallelism

```zig
pub fn pipelineParallelExample(allocator: std.mem.Allocator) !void {
    var engine = try vllm.LLMEngine.init(allocator, .{
        .model_path = "meta-llama/Llama-2-70b-hf",
        .pipeline_parallel_size = 2,
        .tensor_parallel_size = 2,
        // Total: 4 GPUs (2 PP x 2 TP)
    });
    defer engine.deinit();
    
    // Use engine normally
}
```

---

## Custom Sampling

### Advanced Sampling Strategies

```zig
const std = @import("std");
const vllm = @import("vllm");

pub fn customSamplingExamples(allocator: std.mem.Allocator) !void {
    var engine = try vllm.LLMEngine.init(allocator, .{
        .model_path = "meta-llama/Llama-2-7b-hf",
    });
    defer engine.deinit();

    const prompt_tokens = try engine.tokenize(allocator, "Creative writing:");

    // Greedy decoding (deterministic)
    _ = try engine.submitRequest(.{
        .request_id = "greedy",
        .prompt_tokens = prompt_tokens,
        .max_new_tokens = 50,
        .sampling_params = .{
            .temperature = 0.0,  // Greedy
        },
    });

    // High creativity
    _ = try engine.submitRequest(.{
        .request_id = "creative",
        .prompt_tokens = prompt_tokens,
        .max_new_tokens = 50,
        .sampling_params = .{
            .temperature = 1.2,
            .top_p = 0.95,
            .top_k = 100,
        },
    });

    // Focused with repetition penalty
    _ = try engine.submitRequest(.{
        .request_id = "focused",
        .prompt_tokens = prompt_tokens,
        .max_new_tokens = 50,
        .sampling_params = .{
            .temperature = 0.3,
            .top_p = 0.8,
            .repetition_penalty = 1.2,
            .frequency_penalty = 0.5,
        },
    });

    // Reproducible output
    _ = try engine.submitRequest(.{
        .request_id = "reproducible",
        .prompt_tokens = prompt_tokens,
        .max_new_tokens = 50,
        .sampling_params = .{
            .temperature = 0.7,
            .seed = 12345,
        },
    });

    while (engine.hasPendingWork()) {
        _ = try engine.step();
    }
}
```

---

## Structured Output

### JSON Schema Constrained Output

```zig
const std = @import("std");
const vllm = @import("vllm");

pub fn structuredOutputExample(allocator: std.mem.Allocator) !void {
    var engine = try vllm.LLMEngine.init(allocator, .{
        .model_path = "meta-llama/Llama-2-7b-hf",
    });
    defer engine.deinit();

    const json_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": {"type": "string"},
        \\    "age": {"type": "integer"},
        \\    "city": {"type": "string"}
        \\  },
        \\  "required": ["name", "age", "city"]
        \\}
    ;

    const prompt = "Extract person info: John Smith is 35 years old and lives in Boston.";
    const tokens = try engine.tokenize(allocator, prompt);

    _ = try engine.submitRequest(.{
        .request_id = "json-001",
        .prompt_tokens = tokens,
        .max_new_tokens = 100,
        .structured_output = .{
            .format = .json,
            .schema = json_schema,
        },
    });

    while (engine.hasPendingWork()) {
        _ = try engine.step();
    }

    if (engine.getResult("json-001")) |result| {
        const json_output = try engine.detokenize(allocator, result.output_tokens);
        std.debug.print("Structured output: {s}\n", .{json_output});
        // Output: {"name": "John Smith", "age": 35, "city": "Boston"}
    }
}
```

---

## Server Deployment

### Production Server

```zig
const std = @import("std");
const vllm = @import("vllm");

pub fn productionServer(allocator: std.mem.Allocator) !void {
    var server = try vllm.OpenAIServer.init(allocator, .{
        .host = "0.0.0.0",
        .port = 8000,
        .model_path = "meta-llama/Llama-2-7b-hf",
        
        // Performance settings
        .max_concurrent = 100,
        .max_batch_size = 32,
        .timeout_ms = 30000,
        
        // Security
        .enable_cors = true,
        .api_key = std.os.getenv("VLLM_API_KEY"),
        
        // Monitoring
        .enable_metrics = true,
        .metrics_port = 9090,
    });
    defer server.deinit();

    // Graceful shutdown handler
    std.os.sigaction(std.os.SIG.INT, .{
        .handler = .{ .handler = struct {
            fn handler(_: c_int) callconv(.C) void {
                // Signal shutdown
            }
        }.handler },
        .mask = std.os.empty_sigset,
        .flags = 0,
    }, null);

    std.debug.print("Production server starting on :8000\n", .{});
    try server.serve();
}
```

### Health Check Endpoint

```zig
// Server automatically provides:
// GET /health           - Basic health check
// GET /v1/models        - List available models
// GET /metrics          - Prometheus metrics (if enabled)
```

---

## Advanced Patterns

### Prefix Caching

```zig
pub fn prefixCachingExample(allocator: std.mem.Allocator) !void {
    var engine = try vllm.LLMEngine.init(allocator, .{
        .model_path = "meta-llama/Llama-2-7b-hf",
        .kv_cache_config = .{
            .enable_prefix_caching = true,
        },
    });
    defer engine.deinit();

    // Common system prompt - cached after first use
    const system_prompt = "You are a helpful AI assistant. ";

    // First request caches the prefix
    _ = try engine.submitRequest(.{
        .request_id = "cache-1",
        .prompt_tokens = try engine.tokenize(allocator, system_prompt ++ "What is 2+2?"),
        .max_new_tokens = 20,
    });

    // Subsequent requests reuse cached prefix
    _ = try engine.submitRequest(.{
        .request_id = "cache-2",
        .prompt_tokens = try engine.tokenize(allocator, system_prompt ++ "What is the capital of France?"),
        .max_new_tokens = 20,
    });

    while (engine.hasPendingWork()) {
        _ = try engine.step();
    }

    // Check cache hit rate
    const stats = engine.getCacheStats();
    std.debug.print("Cache hit rate: {d:.2}%\n", .{stats.hit_rate * 100});
}
```

### Speculative Decoding

```zig
pub fn speculativeDecodingExample(allocator: std.mem.Allocator) !void {
    var engine = try vllm.LLMEngine.init(allocator, .{
        .model_path = "meta-llama/Llama-2-70b-hf",
        .speculative_config = .{
            .draft_model = "meta-llama/Llama-2-7b-hf",
            .num_speculative_tokens = 5,
        },
    });
    defer engine.deinit();

    // Speculative decoding provides ~2x speedup
    const tokens = try engine.tokenize(allocator, "Explain machine learning:");

    _ = try engine.submitRequest(.{
        .request_id = "spec-001",
        .prompt_tokens = tokens,
        .max_new_tokens = 200,
    });

    while (engine.hasPendingWork()) {
        _ = try engine.step();
    }

    const stats = engine.getSpeculativeStats();
    std.debug.print("Speculation acceptance rate: {d:.2}%\n", .{stats.acceptance_rate * 100});
}
```

---

*Code Examples v1.0 - vLLM Zig Rewrite*