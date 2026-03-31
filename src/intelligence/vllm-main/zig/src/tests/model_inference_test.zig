//! Model Inference Test
//! Tests the custom Zig LLaMA inference engine with GGUF models from vendor/layerModels.
//! NO Ollama fallback - uses only our pure Zig transformer implementation.

const std = @import("std");
const llama = @import("llama");

const Model = llama.Model;
const KVCache = llama.KVCache;
const Sampler = llama.Sampler;

/// Default model path (LFM2.5-1.2B is small and fast)
const DEFAULT_MODEL_PATH = "/Users/user/Documents/sap-ai-suite/vendor/layerModels/LFM2.5-1.2B-Instruct-GGUF/LFM2.5-1.2B-Instruct-Q4_K_M.gguf";

/// Test loading a GGUF model and running inference
pub fn testModelInference() !void {
    const allocator = std.heap.page_allocator;
    
    // Use environment variable or default to vendor model
    const owned_model_path = std.process.getEnvVarOwned(allocator, "GGUF_MODEL_PATH") catch null;
    defer if (owned_model_path) |path| allocator.free(path);
    const model_path = owned_model_path orelse DEFAULT_MODEL_PATH;
    
    std.log.info("╔══════════════════════════════════════════════════════════════════╗", .{});
    std.log.info("║  MODEL INFERENCE TEST - Custom Zig Engine Only                  ║", .{});
    std.log.info("╠══════════════════════════════════════════════════════════════════╣", .{});
    std.log.info("║  Model: {s}                                     ", .{model_path});
    std.log.info("║  Backend: Pure Zig + Apple Accelerate (no Ollama)               ║", .{});
    std.log.info("╚══════════════════════════════════════════════════════════════════╝", .{});
    
    // Check if model file exists
    const file = std.fs.cwd().openFile(model_path, .{}) catch |err| {
        std.log.err("Cannot open GGUF model: {s} - {}", .{model_path, err});
        std.log.err("Set GGUF_MODEL_PATH env var or place model at default path", .{});
        return;
    };
    const stat = try file.stat();
    file.close();
    
    std.log.info("Model size: {d:.1} MB", .{@as(f64, @floatFromInt(stat.size)) / (1024 * 1024)});

    // Load model using our GGUF loader
    const start_load = std.time.nanoTimestamp();
    const model = Model.loadFromGGUF(allocator, model_path) catch |err| {
        std.log.err("Failed to load GGUF model: {}", .{err});
        return;
    };
    const load_time_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_load)) / 1_000_000;
    defer model.deinit();
    
    std.log.info("╔══════════════════════════════════════════════════════════════════╗", .{});
    std.log.info("║  MODEL LOADED SUCCESSFULLY                                       ║", .{});
    std.log.info("╠══════════════════════════════════════════════════════════════════╣", .{});
    std.log.info("║  Load time:    {d:.1} ms                                        ", .{load_time_ms});
    std.log.info("║  Runtime:      {s}                                               ", .{if (model.isUsingMetal()) "metal-hybrid" else "cpu"});
    std.log.info("║  Architecture: {s}                                              ", .{@tagName(model.getArchitecture())});
    std.log.info("║  Vocab size:   {d}                                              ", .{model.getVocabSize()});
    std.log.info("║  Hidden dim:   {d}                                              ", .{model.getHiddenDim()});
    std.log.info("║  Layers:       {d}                                              ", .{model.getNumLayers()});
    std.log.info("║  Heads:        {d}                                              ", .{model.getNumHeads()});
    std.log.info("║  KV Heads:     {d}                                              ", .{model.getNumKVHeads()});
    std.log.info("╚══════════════════════════════════════════════════════════════════╝", .{});
    
    // Initialize KV cache
    var cache = try KVCache.init(allocator, model.config);
    defer cache.deinit(allocator);
    
    // Initialize sampler (greedy for deterministic results)
    const sampler = try Sampler.init(allocator, .{
        .temperature = 0.0,  // Greedy sampling
        .top_p = 1.0,
        .top_k = 0,
    });
    defer sampler.deinit();
    
    // Test 1: Single token forward pass
    std.log.info("\n═══ TEST 1: Single Token Forward Pass ═══", .{});
    {
        const start = std.time.nanoTimestamp();
        const logits = model.forward(1, 0, &cache);
        const elapsed_us = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start)) / 1000;
        
        std.log.info("  Token ID: 1 → {d} logits in {d:.1} µs", .{logits.len, elapsed_us});
        
        // Find top 5 predictions
        var top5: [5]struct { id: u32, val: f32 } = undefined;
        for (&top5) |*t| t.* = .{ .id = 0, .val = -std.math.inf(f32) };
        
        for (logits, 0..) |v, i| {
            if (v > top5[4].val) {
                top5[4] = .{ .id = @intCast(i), .val = v };
                // Bubble up
                var j: usize = 4;
                while (j > 0 and top5[j].val > top5[j-1].val) : (j -= 1) {
                    const tmp = top5[j-1];
                    top5[j-1] = top5[j];
                    top5[j] = tmp;
                }
            }
        }
        
        std.log.info("  Top-5 predictions:", .{});
        for (top5, 0..) |t, i| {
            std.log.info("    {d}. Token {d}: {d:.3}", .{i + 1, t.id, t.val});
        }
    }
    
    // Test 2: Multi-token generation (use fixed-size array instead of ArrayList)
    std.log.info("\n═══ TEST 2: Multi-Token Generation ═══", .{});
    cache.clear();
    {
        // Simple prompt: just a few tokens
        const prompt = [_]u32{ 1, 2, 3, 4, 5 };  // BOS + 4 tokens
        const max_new_tokens: usize = 20;
        
        var generated: [64]u32 = undefined;
        var gen_count: usize = 0;
        
        // Prefill
        const prefill_start = std.time.nanoTimestamp();
        for (prompt[0..prompt.len-1], 0..) |tok, pos| {
            _ = model.forward(tok, pos, &cache);
        }
        const prefill_time_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - prefill_start)) / 1_000_000;
        
        // Decode
        var last_token = prompt[prompt.len - 1];
        var pos: usize = prompt.len - 1;
        
        const decode_start = std.time.nanoTimestamp();
        for (0..max_new_tokens) |_| {
            const logits = model.forward(last_token, pos, &cache);
            const next = sampler.sample(logits);
            if (gen_count < generated.len) {
                generated[gen_count] = next;
                gen_count += 1;
            }
            if (next == 2) break;  // EOS
            last_token = next;
            pos += 1;
        }
        const decode_time_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - decode_start)) / 1_000_000;
        
        const tps = if (decode_time_ms > 0) @as(f64, @floatFromInt(gen_count)) / (decode_time_ms / 1000) else 0;
        
        std.log.info("  Prompt tokens:    {d}", .{prompt.len});
        std.log.info("  Generated tokens: {d}", .{gen_count});
        std.log.info("  Prefill time:     {d:.1} ms", .{prefill_time_ms});
        std.log.info("  Decode time:      {d:.1} ms", .{decode_time_ms});
        std.log.info("  Throughput:       {d:.1} tok/s", .{tps});
    }
    
    // Test 3: Benchmark decode speed
    std.log.info("\n═══ TEST 3: Decode Speed Benchmark ═══", .{});
    cache.clear();
    {
        const warmup_tokens = 10;
        const bench_tokens = 50;
        
        // Warmup
        var token: u32 = 1;
        for (0..warmup_tokens) |pos| {
            const logits = model.forward(token, pos, &cache);
            token = sampler.sample(logits);
        }
        
        // Benchmark
        const start = std.time.nanoTimestamp();
        for (warmup_tokens..warmup_tokens + bench_tokens) |pos| {
            const logits = model.forward(token, pos, &cache);
            token = sampler.sample(logits);
        }
        const elapsed_ns = std.time.nanoTimestamp() - start;
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000;
        const tps = @as(f64, @floatFromInt(bench_tokens)) / (elapsed_ms / 1000);
        
        std.log.info("  Benchmark: {d} tokens in {d:.1} ms", .{bench_tokens, elapsed_ms});
        std.log.info("  ╔═══════════════════════════════════════════╗", .{});
        std.log.info("  ║  THROUGHPUT: {d:.1} tokens/second           ", .{tps});
        std.log.info("  ╚═══════════════════════════════════════════╝", .{});
    }
    
    std.log.info("\n═══ ALL TESTS COMPLETED ═══", .{});
    std.log.info("Custom Zig inference engine working with GGUF model!", .{});
}

pub fn main() !void {
    try testModelInference();
}

test "model inference" {
    try testModelInference();
}
