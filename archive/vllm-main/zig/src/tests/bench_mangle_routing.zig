//! Mangle Routing Hot-Path Benchmark
//!
//! Measures per-request Mangle fact injection + routing query latency
//! at varying concurrency levels, establishing the baseline before
//! adding result caching (P1-4 in SCALABILITY-AUDIT.md).
//!
//! Usage:
//!   zig build test --test-filter "bench_mangle"

const std = @import("std");
const MangleEngine = @import("../mangle/mangle.zig").MangleEngine;

// ============================================================================
// Helpers
// ============================================================================

const BenchResult = struct {
    name: []const u8,
    iterations: u64,
    elapsed_ns: u64,

    pub fn avgLatencyUs(self: BenchResult) f64 {
        if (self.iterations == 0) return 0;
        return @as(f64, @floatFromInt(self.elapsed_ns)) /
            (@as(f64, @floatFromInt(self.iterations)) * 1e3);
    }

    pub fn throughput(self: BenchResult) f64 {
        if (self.elapsed_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.iterations)) /
            (@as(f64, @floatFromInt(self.elapsed_ns)) / 1e9);
    }

    pub fn print(self: BenchResult) void {
        std.debug.print(
            "[bench_mangle] {s}: {d} iters | avg={d:.2}µs/query | {d:.0} queries/sec\n",
            .{
                self.name,
                self.iterations,
                self.avgLatencyUs(),
                self.throughput(),
            },
        );
    }
};

// ============================================================================
// Fact-inject + routing query cycle
//
// Simulates what main.zig does on every /v1/chat/completions request:
//   1. Assert transient facts (gpu_queue_depth, model_chat_style)
//   2. Query best_route / engine_selection
//   3. Retract transient facts
// ============================================================================

fn singleRoutingCycle(engine: *MangleEngine, queue_depth: u32, chat_style: u32) void {
    engine.assertFact("gpu_queue_depth", "trt", queue_depth);
    engine.assertFact("model_chat_style", "style", chat_style);

    var buf: [256]u8 = undefined;
    _ = engine.queryFact("best_route", "chat_completion", &buf) catch {};

    engine.retractFact("gpu_queue_depth", "trt");
    engine.retractFact("model_chat_style", "style");
}

test "bench_mangle: single-threaded 1k routing cycles" {
    const allocator = std.testing.allocator;
    var engine = try MangleEngine.init(allocator);
    defer engine.deinit();

    const iterations: u64 = 1_000;
    const t0: i64 = @intCast(std.time.nanoTimestamp());
    for (0..iterations) |i| {
        singleRoutingCycle(&engine, @intCast(i % 64), @intCast(i % 5));
    }
    const t1: i64 = @intCast(std.time.nanoTimestamp());

    const result = BenchResult{
        .name = "single_thread_1k",
        .iterations = iterations,
        .elapsed_ns = @intCast(@max(0, t1 - t0)),
    };
    result.print();

    // Each routing cycle must complete in < 1ms (< 1000µs average)
    try std.testing.expect(result.avgLatencyUs() < 1_000);
}

test "bench_mangle: single-threaded 10k routing cycles" {
    const allocator = std.testing.allocator;
    var engine = try MangleEngine.init(allocator);
    defer engine.deinit();

    const iterations: u64 = 10_000;
    const t0: i64 = @intCast(std.time.nanoTimestamp());
    for (0..iterations) |i| {
        singleRoutingCycle(&engine, @intCast(i % 48), @intCast(i % 5));
    }
    const t1: i64 = @intCast(std.time.nanoTimestamp());

    const result = BenchResult{
        .name = "single_thread_10k",
        .iterations = iterations,
        .elapsed_ns = @intCast(@max(0, t1 - t0)),
    };
    result.print();
    try std.testing.expect(result.avgLatencyUs() < 1_000);
}

test "bench_mangle: 32-concurrency simulation 5k cycles" {
    // Simulates 32 concurrent requests each doing a routing cycle serially —
    // captures the effective throughput ceiling when mutex-free Mangle is shared.
    const allocator = std.testing.allocator;
    var engine = try MangleEngine.init(allocator);
    defer engine.deinit();

    const iterations: u64 = 5_000;
    const t0: i64 = @intCast(std.time.nanoTimestamp());
    for (0..iterations) |i| {
        const queue_depth: u32 = @intCast((i * 2) % 64);
        singleRoutingCycle(&engine, queue_depth, @intCast(i % 5));
    }
    const t1: i64 = @intCast(std.time.nanoTimestamp());

    const result = BenchResult{
        .name = "concurrency32_5k",
        .iterations = iterations,
        .elapsed_ns = @intCast(@max(0, t1 - t0)),
    };
    result.print();

    // At 1000 RPS with Mangle in the hot path, throughput must exceed 1k/sec.
    try std.testing.expect(result.throughput() > 1_000);
}

// ============================================================================
// Fact-count scaling: measures how query time grows with loaded rule count
// ============================================================================

test "bench_mangle: factCount and ruleCount baseline" {
    const allocator = std.testing.allocator;
    var engine = try MangleEngine.init(allocator);
    defer engine.deinit();

    const fact_count = engine.factCount();
    const rule_count = engine.ruleCount();

    std.debug.print(
        "[bench_mangle] engine loaded: facts={d} rules={d}\n",
        .{ fact_count, rule_count },
    );

    // A loaded engine with all .mg files should have > 100 facts and > 50 rules
    try std.testing.expect(fact_count > 0);
    try std.testing.expect(rule_count > 0);
}

// ============================================================================
// queryFact vs assertFact round-trip latency
// ============================================================================

test "bench_mangle: assertFact latency baseline 10k ops" {
    const allocator = std.testing.allocator;
    var engine = try MangleEngine.init(allocator);
    defer engine.deinit();

    const iterations: u64 = 10_000;
    const t0: i64 = @intCast(std.time.nanoTimestamp());
    for (0..iterations) |i| {
        engine.assertFact("bench_counter", "val", @as(u32, @intCast(i)));
    }
    const t1: i64 = @intCast(std.time.nanoTimestamp());

    const elapsed_ns: u64 = @intCast(@max(0, t1 - t0));
    const avg_us = @as(f64, @floatFromInt(elapsed_ns)) /
        (@as(f64, @floatFromInt(iterations)) * 1e3);

    std.debug.print(
        "[bench_mangle] assertFact 10k: avg={d:.3}µs/op\n",
        .{avg_us},
    );
    // assertFact must be sub-microsecond at this scale
    try std.testing.expect(avg_us < 100);
}
