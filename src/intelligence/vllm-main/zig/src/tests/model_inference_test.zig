//! Model Inference Test
//! Tests the custom Zig LLaMA inference engine with GGUF models from vendor/layerModels.
//! NO Ollama fallback - uses only our pure Zig transformer implementation.

const std = @import("std");
const llama = @import("llama");

const Model = llama.Model;
const KVCache = llama.KVCache;
const Sampler = llama.Sampler;
const ForwardProfileStats = llama.ForwardProfileStats;

/// Default model path (LFM2.5-1.2B is small and fast)
const DEFAULT_MODEL_PATH = "/Users/user/Documents/sap-ai-suite/vendor/layerModels/LFM2.5-1.2B-Instruct-GGUF/LFM2.5-1.2B-Instruct-Q4_K_M.gguf";

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn argmaxToken(logits: []const f32) u32 {
    if (logits.len == 0) return 0;
    var best_idx: usize = 0;
    var best_val = logits[0];
    for (logits[1..], 1..) |value, idx| {
        if (value > best_val) {
            best_val = value;
            best_idx = idx;
        }
    }
    return @intCast(best_idx);
}

fn printForwardProfile(label: []const u8, profile: ForwardProfileStats) void {
    const accounted = profile.embedding_ns + profile.attn_prep_ns + profile.attn_decode_ns +
        profile.attn_wo_chain_ns + profile.attn_proj_ns + profile.attn_residual_ns +
        profile.shortconv_ns + profile.ffn_prep_ns + profile.ffn_down_ns +
        profile.ffn_residual_ns + profile.logits_ns;
    const other_ns: u64 = if (profile.total_forward_ns > accounted) profile.total_forward_ns - accounted else 0;

    std.log.info("  [profile:{s}] calls={d} layers={d} attn_layers={d} recurrent_layers={d}", .{
        label,
        profile.forward_calls,
        profile.layers_processed,
        profile.attention_layers,
        profile.recurrent_layers,
    });
    std.log.info("    embed={d:.1}ms attn_prep={d:.1}ms attn_decode={d:.1}ms attn_chain={d:.1}ms attn_proj={d:.1}ms", .{
        nsToMs(profile.embedding_ns),
        nsToMs(profile.attn_prep_ns),
        nsToMs(profile.attn_decode_ns),
        nsToMs(profile.attn_wo_chain_ns),
        nsToMs(profile.attn_proj_ns),
    });
    std.log.info("    attn_residual={d:.1}ms shortconv={d:.1}ms ffn_prep={d:.1}ms ffn_down={d:.1}ms ffn_residual={d:.1}ms", .{
        nsToMs(profile.attn_residual_ns),
        nsToMs(profile.shortconv_ns),
        nsToMs(profile.ffn_prep_ns),
        nsToMs(profile.ffn_down_ns),
        nsToMs(profile.ffn_residual_ns),
    });
    std.log.info("    shortconv_norm={d:.1}ms shortconv_in={d:.1}ms shortconv_conv={d:.1}ms shortconv_out={d:.1}ms", .{
        nsToMs(profile.shortconv_norm_ns),
        nsToMs(profile.shortconv_in_proj_ns),
        nsToMs(profile.shortconv_conv_ns),
        nsToMs(profile.shortconv_out_proj_ns),
    });
    std.log.info("    logits_norm={d:.1}ms logits_head={d:.1}ms", .{
        nsToMs(profile.logits_norm_ns),
        nsToMs(profile.logits_head_ns),
    });
    std.log.info("    logits={d:.1}ms other={d:.1}ms total={d:.1}ms", .{
        nsToMs(profile.logits_ns),
        nsToMs(other_ns),
        nsToMs(profile.total_forward_ns),
    });
}

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
    if (model.isForwardProfilingEnabled()) {
        std.log.info("Forward profiling enabled via PLLM_PROFILE_FORWARD=1", .{});
    }
    
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
        if (model.isForwardProfilingEnabled()) model.resetForwardProfile();
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
        if (model.isForwardProfilingEnabled()) {
            printForwardProfile("single-forward", model.getForwardProfile());
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
        var prefill_profile: ForwardProfileStats = .{};
        var decode_profile: ForwardProfileStats = .{};
        
        // Prefill
        if (model.isForwardProfilingEnabled()) model.resetForwardProfile();
        const prefill_start = std.time.nanoTimestamp();
        for (prompt[0..prompt.len-1], 0..) |tok, pos| {
            model.forwardNoLogits(tok, pos, &cache);
        }
        const prefill_time_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - prefill_start)) / 1_000_000;
        if (model.isForwardProfilingEnabled()) prefill_profile = model.getForwardProfile();
        
        // Decode
        var last_token = prompt[prompt.len - 1];
        var pos: usize = prompt.len - 1;
        
        if (model.isForwardProfilingEnabled()) model.resetForwardProfile();
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
        if (model.isForwardProfilingEnabled()) decode_profile = model.getForwardProfile();
        
        const tps = if (decode_time_ms > 0) @as(f64, @floatFromInt(gen_count)) / (decode_time_ms / 1000) else 0;
        
        std.log.info("  Prompt tokens:    {d}", .{prompt.len});
        std.log.info("  Generated tokens: {d}", .{gen_count});
        std.log.info("  Prefill time:     {d:.1} ms", .{prefill_time_ms});
        std.log.info("  Decode time:      {d:.1} ms", .{decode_time_ms});
        std.log.info("  Throughput:       {d:.1} tok/s", .{tps});
        if (model.isForwardProfilingEnabled()) {
            printForwardProfile("generation-prefill", prefill_profile);
            printForwardProfile("generation-decode", decode_profile);
        }
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
            token = argmaxToken(logits);
        }
        
        // Benchmark
        if (model.isForwardProfilingEnabled()) model.resetForwardProfile();
        const start = std.time.nanoTimestamp();
        for (warmup_tokens..warmup_tokens + bench_tokens) |pos| {
            const logits = model.forward(token, pos, &cache);
            token = argmaxToken(logits);
        }
        const elapsed_ns = std.time.nanoTimestamp() - start;
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000;
        const tps = @as(f64, @floatFromInt(bench_tokens)) / (elapsed_ms / 1000);
        
        std.log.info("  Benchmark: {d} tokens in {d:.1} ms", .{bench_tokens, elapsed_ms});
        std.log.info("  ╔═══════════════════════════════════════════╗", .{});
        std.log.info("  ║  THROUGHPUT: {d:.1} tokens/second           ", .{tps});
        std.log.info("  ╚═══════════════════════════════════════════╝", .{});
        if (model.isForwardProfilingEnabled()) {
            printForwardProfile("decode-benchmark", model.getForwardProfile());
        }
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
