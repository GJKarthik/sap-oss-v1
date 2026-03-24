//! Paged KV Cache Allocation / Eviction Benchmark
//!
//! Measures PagedKvCache block alloc and evict throughput under varying
//! batch sizes. Establishes baseline before deriving block count from VRAM
//! at runtime (P2-3 in SCALABILITY-AUDIT.md).
//!
//! Usage:
//!   zig build test --test-filter "bench_kv_cache"

const std = @import("std");

// ============================================================================
// Minimal PagedKvCache stub
// Mirrors the production interface in llm/batch_scheduler.zig so that
// the benchmark compiles without a GPU. Swap @import path when running
// with the full build.
// ============================================================================

const KV_BLOCK_SIZE: u32 = 256; // Must match Mojo KV_BLOCK_SIZE

const PagedKvCache = struct {
    allocator: std.mem.Allocator,
    total_blocks: u32,
    block_size: u32,
    free_blocks: std.ArrayList(u32),
    used_blocks: u32,

    pub fn init(allocator: std.mem.Allocator, total_blocks: u32) !PagedKvCache {
        var free = std.ArrayList(u32).init(allocator);
        try free.ensureTotalCapacity(total_blocks);
        for (0..total_blocks) |i| {
            try free.append(@intCast(i));
        }
        return .{
            .allocator = allocator,
            .total_blocks = total_blocks,
            .block_size = KV_BLOCK_SIZE,
            .free_blocks = free,
            .used_blocks = 0,
        };
    }

    pub fn deinit(self: *PagedKvCache) void {
        self.free_blocks.deinit();
    }

    /// Allocate `n` blocks. Returns false if insufficient free blocks.
    pub fn allocBlocks(self: *PagedKvCache, n: u32) bool {
        if (self.free_blocks.items.len < n) return false;
        const new_len = self.free_blocks.items.len - n;
        self.free_blocks.shrinkRetainingCapacity(new_len);
        self.used_blocks += n;
        return true;
    }

    /// Free `n` blocks back to the pool (simplified: push dummy IDs).
    pub fn freeBlocks(self: *PagedKvCache, n: u32) void {
        for (0..n) |_| {
            self.free_blocks.append(self.used_blocks) catch {};
        }
        self.used_blocks -|= n;
    }

    pub fn freeCount(self: *const PagedKvCache) u32 {
        return @intCast(self.free_blocks.items.len);
    }
};

// ============================================================================
// Benchmark helpers
// ============================================================================

const BenchResult = struct {
    name: []const u8,
    ops: u64,
    elapsed_ns: u64,

    pub fn throughput(self: BenchResult) f64 {
        if (self.elapsed_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.ops)) /
            (@as(f64, @floatFromInt(self.elapsed_ns)) / 1e9);
    }

    pub fn avgLatencyNs(self: BenchResult) f64 {
        if (self.ops == 0) return 0;
        return @as(f64, @floatFromInt(self.elapsed_ns)) /
            @as(f64, @floatFromInt(self.ops));
    }

    pub fn print(self: BenchResult) void {
        std.debug.print(
            "[bench_kv_cache] {s}: {d} ops in {d:.2}ms | " ++
                "avg={d:.1}ns/op | {d:.0} ops/sec\n",
            .{
                self.name,
                self.ops,
                @as(f64, @floatFromInt(self.elapsed_ns)) / 1e6,
                self.avgLatencyNs(),
                self.throughput(),
            },
        );
    }
};

// ============================================================================
// Alloc+free cycle benchmarks
// ============================================================================

test "bench_kv_cache: batch_size=1, 10k alloc+free cycles" {
    const allocator = std.testing.allocator;
    var cache = try PagedKvCache.init(allocator, 1024);
    defer cache.deinit();

    const iterations: u64 = 10_000;
    const blocks_per_req: u32 = 1; // 1 block = 256 tokens per request

    const t0: i64 = @intCast(std.time.nanoTimestamp());
    for (0..iterations) |_| {
        _ = cache.allocBlocks(blocks_per_req);
        cache.freeBlocks(blocks_per_req);
    }
    const t1: i64 = @intCast(std.time.nanoTimestamp());

    const result = BenchResult{
        .name = "batch1_10k",
        .ops = iterations,
        .elapsed_ns = @intCast(@max(0, t1 - t0)),
    };
    result.print();
    try std.testing.expect(result.throughput() > 1_000_000); // > 1M ops/sec
}

test "bench_kv_cache: batch_size=16, 5k alloc+free cycles" {
    const allocator = std.testing.allocator;
    var cache = try PagedKvCache.init(allocator, 1024);
    defer cache.deinit();

    const iterations: u64 = 5_000;
    const blocks_per_req: u32 = 16; // 16×256 = 4096 tokens (full context)

    const t0: i64 = @intCast(std.time.nanoTimestamp());
    for (0..iterations) |_| {
        if (!cache.allocBlocks(blocks_per_req)) {
            cache.freeBlocks(blocks_per_req); // evict to make room
            _ = cache.allocBlocks(blocks_per_req);
        }
        cache.freeBlocks(blocks_per_req);
    }
    const t1: i64 = @intCast(std.time.nanoTimestamp());

    const result = BenchResult{
        .name = "batch16_5k",
        .ops = iterations,
        .elapsed_ns = @intCast(@max(0, t1 - t0)),
    };
    result.print();
    try std.testing.expect(result.throughput() > 100_000);
}

test "bench_kv_cache: batch_size=64, 1k alloc+free cycles" {
    const allocator = std.testing.allocator;
    var cache = try PagedKvCache.init(allocator, 1024);
    defer cache.deinit();

    const iterations: u64 = 1_000;
    const blocks_per_req: u32 = 64;

    const t0: i64 = @intCast(std.time.nanoTimestamp());
    for (0..iterations) |_| {
        if (!cache.allocBlocks(blocks_per_req)) {
            cache.freeBlocks(blocks_per_req);
            _ = cache.allocBlocks(blocks_per_req);
        }
        cache.freeBlocks(blocks_per_req);
    }
    const t1: i64 = @intCast(std.time.nanoTimestamp());

    const result = BenchResult{
        .name = "batch64_1k",
        .ops = iterations,
        .elapsed_ns = @intCast(@max(0, t1 - t0)),
    };
    result.print();
    try std.testing.expect(result.throughput() > 10_000);
}

test "bench_kv_cache: batch_size=256, 500 alloc+free cycles" {
    const allocator = std.testing.allocator;
    var cache = try PagedKvCache.init(allocator, 1024);
    defer cache.deinit();

    const iterations: u64 = 500;
    const blocks_per_req: u32 = 256;

    const t0: i64 = @intCast(std.time.nanoTimestamp());
    for (0..iterations) |_| {
        if (!cache.allocBlocks(blocks_per_req)) {
            cache.freeBlocks(256);
            _ = cache.allocBlocks(blocks_per_req);
        }
        cache.freeBlocks(blocks_per_req);
    }
    const t1: i64 = @intCast(std.time.nanoTimestamp());

    const result = BenchResult{
        .name = "batch256_500",
        .ops = iterations,
        .elapsed_ns = @intCast(@max(0, t1 - t0)),
    };
    result.print();
    _ = result;
}

// ============================================================================
// Capacity utilisation test: verify block count math at T4 VRAM budget
// ============================================================================

test "bench_kv_cache: T4 VRAM budget block count calculation" {
    // T4 has 16 GiB VRAM. Model (Q4_K_M 7B) uses ~4.5 GiB.
    // Remaining for KV cache: ~11.5 GiB
    // Each block: KV_BLOCK_SIZE(256) × 2(K+V) × 32(heads) × 128(head_dim) × 2(f16) bytes
    //           = 256 × 2 × 32 × 128 × 2 = 4,194,304 bytes = 4 MiB
    // Max blocks at 11.5 GiB: 11.5 * 1024 / 4 = 2944 blocks
    // Current hardcoded value: 1024 blocks = only 4 GiB KV cache (35% utilisation)

    const t4_vram_bytes: u64 = 16 * 1024 * 1024 * 1024;
    const model_vram_bytes: u64 = 4_500_000_000; // ~4.5 GiB for Q4_K_M 7B
    const available_bytes = t4_vram_bytes - model_vram_bytes;

    const n_heads: u32 = 32;
    const head_dim: u32 = 128;
    const bytes_per_element: u32 = 2; // f16
    const kv_factor: u32 = 2; // K + V
    const bytes_per_block: u64 = KV_BLOCK_SIZE * kv_factor * n_heads * head_dim * bytes_per_element;
    const optimal_blocks: u64 = available_bytes / bytes_per_block;

    std.debug.print(
        "[bench_kv_cache] T4 VRAM budget:\n" ++
            "  available_for_kv={d:.1} GiB\n" ++
            "  bytes_per_block={d} bytes ({d:.1} MiB)\n" ++
            "  optimal_blocks={d}\n" ++
            "  current_hardcoded=1024 ({d:.0}% utilisation)\n",
        .{
            @as(f64, @floatFromInt(available_bytes)) / (1024 * 1024 * 1024),
            bytes_per_block,
            @as(f64, @floatFromInt(bytes_per_block)) / (1024 * 1024),
            optimal_blocks,
            @as(f64, 1024.0) / @as(f64, @floatFromInt(optimal_blocks)) * 100.0,
        },
    );

    // The hardcoded 1024 leaves significant VRAM unused — document as finding
    // P2-3: derive block count from available VRAM at runtime
    try std.testing.expect(optimal_blocks > 1024);
    try std.testing.expectEqual(@as(u32, 256), KV_BLOCK_SIZE);
}
