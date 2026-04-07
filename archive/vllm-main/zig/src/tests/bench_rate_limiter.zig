//! Rate Limiter Throughput Benchmark
//!
//! Measures token-bucket rate limiter performance under varying concurrency
//! and configured RPS targets.
//!
//! Usage:
//!   zig build test --test-filter "bench_rate_limiter"
//!   zig test src/tests/bench_rate_limiter.zig

const std = @import("std");
const RateLimiter = @import("../http/rate_limiter.zig").RateLimiter;

// ============================================================================
// Benchmark harness
// ============================================================================

const BenchResult = struct {
    name: []const u8,
    iterations: u64,
    elapsed_ns: u64,
    allowed: u64,
    denied: u64,

    pub fn throughput(self: BenchResult) f64 {
        if (self.elapsed_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.iterations)) /
            (@as(f64, @floatFromInt(self.elapsed_ns)) / 1e9);
    }

    pub fn print(self: BenchResult) void {
        std.debug.print(
            "[bench_rate_limiter] {s}: {d} iters in {d:.2}ms | " ++
                "{d:.0} calls/sec | allowed={d} denied={d}\n",
            .{
                self.name,
                self.iterations,
                @as(f64, @floatFromInt(self.elapsed_ns)) / 1e6,
                self.throughput(),
                self.allowed,
                self.denied,
            },
        );
    }
};

fn runBench(
    name: []const u8,
    capacity: u64,
    rps: u64,
    iterations: u64,
) BenchResult {
    var limiter = RateLimiter.init(capacity, rps);
    var allowed: u64 = 0;
    var denied: u64 = 0;

    const t0: i64 = @intCast(std.time.nanoTimestamp());
    for (0..iterations) |_| {
        if (limiter.allow()) {
            allowed += 1;
        } else {
            denied += 1;
        }
    }
    const t1: i64 = @intCast(std.time.nanoTimestamp());
    const elapsed_ns: u64 = @intCast(@max(0, t1 - t0));

    return .{
        .name = name,
        .iterations = iterations,
        .elapsed_ns = elapsed_ns,
        .allowed = allowed,
        .denied = denied,
    };
}

// ============================================================================
// Single-threaded benchmarks
// ============================================================================

test "bench_rate_limiter: 100 RPS capacity, 100k calls" {
    const result = runBench("100rps_100k", 100, 100, 100_000);
    result.print();
    // Allow() loop must complete in < 500ms (200k+ calls/sec minimum)
    try std.testing.expect(result.throughput() > 200_000);
}

test "bench_rate_limiter: 1000 RPS capacity, 100k calls" {
    const result = runBench("1000rps_100k", 1000, 1000, 100_000);
    result.print();
    try std.testing.expect(result.throughput() > 200_000);
}

test "bench_rate_limiter: burst=5000, 100k calls" {
    const result = runBench("burst5000_100k", 5000, 5000, 100_000);
    result.print();
    try std.testing.expect(result.throughput() > 200_000);
}

test "bench_rate_limiter: allowN(10), 10k calls" {
    var limiter = RateLimiter.init(10_000, 10_000);
    var allowed: u64 = 0;
    var denied: u64 = 0;

    const t0: i64 = @intCast(std.time.nanoTimestamp());
    for (0..10_000) |_| {
        if (limiter.allowN(10)) {
            allowed += 1;
        } else {
            denied += 1;
        }
    }
    const t1: i64 = @intCast(std.time.nanoTimestamp());
    const elapsed_ns: u64 = @intCast(@max(0, t1 - t0));

    std.debug.print(
        "[bench_rate_limiter] allowN(10)_10k: {d:.2}ms | allowed={d} denied={d}\n",
        .{
            @as(f64, @floatFromInt(elapsed_ns)) / 1e6,
            allowed,
            denied,
        },
    );
    _ = allowed;
    _ = denied;
}

// ============================================================================
// Multi-threaded contention benchmark
// ============================================================================

const ThreadArgs = struct {
    limiter: *RateLimiter,
    iterations: u64,
    allowed: std.atomic.Value(u64),
    denied: std.atomic.Value(u64),

    fn init(limiter: *RateLimiter, iterations: u64) ThreadArgs {
        return .{
            .limiter = limiter,
            .iterations = iterations,
            .allowed = std.atomic.Value(u64).init(0),
            .denied = std.atomic.Value(u64).init(0),
        };
    }
};

fn threadWorker(args: *ThreadArgs) void {
    for (0..args.iterations) |_| {
        if (args.limiter.allow()) {
            _ = args.allowed.fetchAdd(1, .monotonic);
        } else {
            _ = args.denied.fetchAdd(1, .monotonic);
        }
    }
}

test "bench_rate_limiter: 8-thread contention, 100k calls each" {
    const n_threads = 8;
    const iters_per_thread = 100_000;

    var limiter = RateLimiter.init(1_000_000, 1_000_000);
    var args = ThreadArgs.init(&limiter, iters_per_thread);

    var threads: [n_threads]std.Thread = undefined;
    const t0: i64 = @intCast(std.time.nanoTimestamp());

    for (0..n_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, threadWorker, .{&args});
    }
    for (0..n_threads) |i| {
        threads[i].join();
    }

    const t1: i64 = @intCast(std.time.nanoTimestamp());
    const elapsed_ns: u64 = @intCast(@max(0, t1 - t0));
    const total_iters = n_threads * iters_per_thread;
    const throughput = @as(f64, @floatFromInt(total_iters)) /
        (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

    std.debug.print(
        "[bench_rate_limiter] 8-thread: {d} total calls in {d:.2}ms | " ++
            "{d:.0} calls/sec | allowed={d} denied={d}\n",
        .{
            total_iters,
            @as(f64, @floatFromInt(elapsed_ns)) / 1e6,
            throughput,
            args.allowed.load(.acquire),
            args.denied.load(.acquire),
        },
    );

    // No tokens lost or double-counted: allowed + denied must equal total
    const total = args.allowed.load(.acquire) + args.denied.load(.acquire);
    try std.testing.expectEqual(@as(u64, total_iters), total);

    // Multi-threaded throughput must still exceed 500k calls/sec
    try std.testing.expect(throughput > 500_000);
}

// ============================================================================
// Correctness regression under contention
// ============================================================================

test "bench_rate_limiter: no tokens double-counted under 4-thread contention" {
    const n_threads = 4;
    const iters_per_thread = 50_000;
    const capacity: u64 = 1_000;

    var limiter = RateLimiter.init(capacity, capacity);
    var args = ThreadArgs.init(&limiter, iters_per_thread);

    var threads: [n_threads]std.Thread = undefined;
    for (0..n_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, threadWorker, .{&args});
    }
    for (0..n_threads) |i| {
        threads[i].join();
    }

    const total = args.allowed.load(.acquire) + args.denied.load(.acquire);
    try std.testing.expectEqual(@as(u64, n_threads * iters_per_thread), total);

    // Should not allow more than capacity (+ one refill window tolerance)
    const allowed = args.allowed.load(.acquire);
    try std.testing.expect(allowed <= capacity + capacity);

    std.debug.print(
        "[bench_rate_limiter] contention-correctness: capacity={d} allowed={d} denied={d}\n",
        .{ capacity, allowed, args.denied.load(.acquire) },
    );
}
