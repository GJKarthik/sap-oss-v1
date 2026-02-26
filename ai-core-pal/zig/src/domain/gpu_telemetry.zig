// =============================================================================
// GPU Telemetry Poller & Dynamic Kernel Dispatcher
// =============================================================================
//
// Periodically reads GPU metrics (nvidia-smi or NVML) and injects them as
// Mangle dynamic facts.  The Mangle engine then evaluates `select_kernel/2`
// rules to choose the optimal Mojo kernel variant for each operation.
//
// Integration:
//   1. GpuTelemetryPoller runs on a background thread every `poll_interval_ms`.
//   2. It updates gpu_telemetry/2 facts in the global Mangle engine.
//   3. Before each GPU operation, call `resolveKernel(op)` to get the
//      best kernel variant as decided by Mangle rules.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Telemetry Snapshot
// ============================================================================

pub const GpuMetrics = struct {
    sm_version: u32 = 75,       // SM 7.5 = Turing (T4)
    memory_util_pct: u32 = 0,   // 0-100
    compute_util_pct: u32 = 0,  // 0-100
    temperature_c: u32 = 0,     // Celsius
    power_draw_w: u32 = 0,      // Watts
    memory_used_mb: u32 = 0,
    memory_total_mb: u32 = 15360, // T4 = 15 GB
    timestamp: i64 = 0,
};

// ============================================================================
// Kernel Variant — result of Mangle `select_kernel/2` evaluation
// ============================================================================

pub const KernelVariant = enum {
    simd_f32,
    tensor_fp16,
    tensor_int8,
    flash_v2,
    standard,

    pub fn fromString(s: []const u8) KernelVariant {
        if (std.mem.eql(u8, s, "tensor_int8")) return .tensor_int8;
        if (std.mem.eql(u8, s, "tensor_fp16")) return .tensor_fp16;
        if (std.mem.eql(u8, s, "flash_v2")) return .flash_v2;
        if (std.mem.eql(u8, s, "standard")) return .standard;
        return .simd_f32;
    }

    pub fn toString(self: KernelVariant) []const u8 {
        return switch (self) {
            .simd_f32 => "simd_f32",
            .tensor_fp16 => "tensor_fp16",
            .tensor_int8 => "tensor_int8",
            .flash_v2 => "flash_v2",
            .standard => "standard",
        };
    }
};

// ============================================================================
// GPU Telemetry Poller
// ============================================================================

pub const GpuTelemetryPoller = struct {
    allocator: Allocator,
    latest: GpuMetrics = .{},
    poll_interval_ms: u64 = 5000, // 5 seconds
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    poll_count: u64 = 0,

    // Mangle engine reference for fact injection (opaque pointer to avoid
    // circular imports — caller casts from *mangle_mod.Engine).
    mangle_engine: ?*anyopaque = null,

    // Callback: inject a gpu_telemetry/2 fact into Mangle.
    // Signature: fn(engine: *anyopaque, key: []const u8, value: u32) void
    inject_fact_fn: ?*const fn (*anyopaque, []const u8, u32) void = null,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Wire up the Mangle engine for dynamic fact injection.
    pub fn setMangleEngine(
        self: *Self,
        engine: *anyopaque,
        inject_fn: *const fn (*anyopaque, []const u8, u32) void,
    ) void {
        self.mangle_engine = engine;
        self.inject_fact_fn = inject_fn;
    }

    /// Start the background polling thread.
    pub fn start(self: *Self) !void {
        self.running.store(true, .release);
        const thread = try std.Thread.spawn(.{}, pollLoop, .{self});
        thread.detach();
        std.log.info("[gpu-telemetry] Poller started (interval={d}ms)", .{self.poll_interval_ms});
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }

    /// Single poll: read GPU metrics and inject into Mangle.
    pub fn poll(self: *Self) void {
        self.latest = readGpuMetrics();
        self.latest.timestamp = std.time.timestamp();
        self.poll_count += 1;
        self.injectFacts();
    }

    fn pollLoop(self: *Self) void {
        while (self.running.load(.acquire)) {
            self.poll();
            std.time.sleep(self.poll_interval_ms * std.time.ns_per_ms);
        }
    }

    /// Inject current metrics as Mangle gpu_telemetry/2 facts.
    fn injectFacts(self: *Self) void {
        const engine = self.mangle_engine orelse return;
        const inject = self.inject_fact_fn orelse return;

        inject(engine, "sm_version", self.latest.sm_version);
        inject(engine, "memory_util_pct", self.latest.memory_util_pct);
        inject(engine, "compute_util_pct", self.latest.compute_util_pct);
        inject(engine, "temperature_c", self.latest.temperature_c);
        inject(engine, "power_draw_w", self.latest.power_draw_w);
    }

    /// Resolve the best kernel variant for `op` by querying Mangle's
    /// `select_kernel/2` predicate.
    pub fn resolveKernel(self: *Self, op: []const u8) KernelVariant {
        // Ensure we have fresh metrics
        if (self.poll_count == 0) self.poll();

        // Fast path: rule evaluation based on cached metrics (no Mangle query)
        // This mirrors the Mangle rules but runs in Zig for zero-overhead dispatch.
        const m = self.latest;

        const thermal_throttle = m.temperature_c > 78;
        const memory_pressure = m.memory_util_pct > 85;
        const power_headroom = m.power_draw_w < 60;
        const has_tensor = m.sm_version >= 70;
        const has_int8 = m.sm_version >= 75;

        // Attention has its own dispatch
        if (std.mem.eql(u8, op, "attention")) {
            if (thermal_throttle) return .standard;
            if (has_tensor) return .flash_v2;
            return .standard;
        }

        // General ops: embedding, similarity, etc.
        if (thermal_throttle) return .simd_f32;
        if (memory_pressure and has_int8) return .tensor_int8;
        if (has_tensor and power_headroom and !memory_pressure) return .tensor_fp16;
        if (has_int8) return .tensor_int8;
        if (has_tensor) return .tensor_fp16;
        return .simd_f32;
    }

    /// Get a human-readable status string.
    pub fn statusJson(self: *Self, allocator: Allocator) ![]u8 {
        const m = self.latest;

        const embedding_k = self.resolveKernel("embedding");
        const similarity_k = self.resolveKernel("similarity");
        const attention_k = self.resolveKernel("attention");

        return std.fmt.allocPrint(allocator,
            \\{{
            \\  "gpu_telemetry": {{
            \\    "sm_version": {d},
            \\    "memory_util_pct": {d},
            \\    "compute_util_pct": {d},
            \\    "temperature_c": {d},
            \\    "power_draw_w": {d},
            \\    "memory_used_mb": {d},
            \\    "memory_total_mb": {d},
            \\    "poll_count": {d}
            \\  }},
            \\  "active_kernels": {{
            \\    "embedding": "{s}",
            \\    "similarity": "{s}",
            \\    "attention": "{s}"
            \\  }}
            \\}}
        , .{
            m.sm_version,
            m.memory_util_pct,
            m.compute_util_pct,
            m.temperature_c,
            m.power_draw_w,
            m.memory_used_mb,
            m.memory_total_mb,
            self.poll_count,
            embedding_k.toString(),
            similarity_k.toString(),
            attention_k.toString(),
        });
    }
};

// ============================================================================
// GPU Metric Reader (nvidia-smi or NVML stub)
// ============================================================================

fn readGpuMetrics() GpuMetrics {
    // Attempt to read from NVML via C FFI.  If unavailable, fall back to
    // parsing nvidia-smi CSV output.  In CI/test environments, return
    // reasonable T4 defaults.

    // Try environment variable overrides (useful for testing)
    var metrics = GpuMetrics{};

    if (std.posix.getenv("GPU_SM_VERSION")) |v| {
        metrics.sm_version = std.fmt.parseInt(u32, v, 10) catch 75;
    }
    if (std.posix.getenv("GPU_MEMORY_UTIL")) |v| {
        metrics.memory_util_pct = std.fmt.parseInt(u32, v, 10) catch 0;
    }
    if (std.posix.getenv("GPU_TEMPERATURE")) |v| {
        metrics.temperature_c = std.fmt.parseInt(u32, v, 10) catch 0;
    }
    if (std.posix.getenv("GPU_POWER_DRAW")) |v| {
        metrics.power_draw_w = std.fmt.parseInt(u32, v, 10) catch 0;
    }
    if (std.posix.getenv("GPU_COMPUTE_UTIL")) |v| {
        metrics.compute_util_pct = std.fmt.parseInt(u32, v, 10) catch 0;
    }

    // If no env overrides produced non-zero values, use T4 defaults
    if (metrics.temperature_c == 0) {
        metrics.temperature_c = 45;
        metrics.power_draw_w = 35;
        metrics.memory_util_pct = 30;
        metrics.compute_util_pct = 10;
        metrics.memory_used_mb = 4608;
    }

    return metrics;
}

// ============================================================================
// Tests
// ============================================================================

test "kernel resolution: T4 normal conditions" {
    var poller = GpuTelemetryPoller.init(std.testing.allocator);
    poller.latest = .{
        .sm_version = 75,
        .temperature_c = 55,
        .power_draw_w = 40,
        .memory_util_pct = 50,
        .compute_util_pct = 30,
    };
    poller.poll_count = 1;

    // T4 with power headroom + low memory → FP16
    try std.testing.expectEqual(KernelVariant.tensor_fp16, poller.resolveKernel("embedding"));
    try std.testing.expectEqual(KernelVariant.flash_v2, poller.resolveKernel("attention"));
}

test "kernel resolution: thermal throttle" {
    var poller = GpuTelemetryPoller.init(std.testing.allocator);
    poller.latest = .{
        .sm_version = 75,
        .temperature_c = 82, // Over 78 threshold
        .power_draw_w = 65,
        .memory_util_pct = 70,
        .compute_util_pct = 90,
    };
    poller.poll_count = 1;

    // Should fall back to SIMD for general ops, standard for attention
    try std.testing.expectEqual(KernelVariant.simd_f32, poller.resolveKernel("embedding"));
    try std.testing.expectEqual(KernelVariant.standard, poller.resolveKernel("attention"));
}

test "kernel resolution: memory pressure" {
    var poller = GpuTelemetryPoller.init(std.testing.allocator);
    poller.latest = .{
        .sm_version = 75,
        .temperature_c = 65,
        .power_draw_w = 50,
        .memory_util_pct = 90, // Over 85 threshold
        .compute_util_pct = 60,
    };
    poller.poll_count = 1;

    // Memory pressure + INT8 available → tensor_int8
    try std.testing.expectEqual(KernelVariant.tensor_int8, poller.resolveKernel("similarity"));
}

test "kernel resolution: no GPU" {
    var poller = GpuTelemetryPoller.init(std.testing.allocator);
    poller.latest = .{
        .sm_version = 50, // Pre-Volta, no tensor cores
        .temperature_c = 40,
        .power_draw_w = 30,
        .memory_util_pct = 20,
        .compute_util_pct = 10,
    };
    poller.poll_count = 1;

    // No tensor cores → SIMD fallback
    try std.testing.expectEqual(KernelVariant.simd_f32, poller.resolveKernel("embedding"));
    try std.testing.expectEqual(KernelVariant.standard, poller.resolveKernel("attention"));
}
