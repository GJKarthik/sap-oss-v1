//! Graceful Shutdown Manager — production hardening for signal handling and request draining
//!
//! Handles SIGTERM/SIGINT for clean shutdown:
//!   1. Stop accepting new connections
//!   2. Wait for in-flight requests to complete (configurable timeout)
//!   3. Close all connections
//!   4. Exit with status 0
//!
//! Also provides startup/readiness/liveness probe handlers for Kubernetes.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

// ============================================================================
// Shutdown State Machine
// ============================================================================

pub const ShutdownPhase = enum {
    running,
    draining, // Stop accepting, drain in-flight
    closing, // Force-close remaining
    stopped,
};

pub const ShutdownConfig = struct {
    drain_timeout_ms: u64 = 30_000, // 30s default
    force_close_timeout_ms: u64 = 5_000,
    health_check_interval_ms: u64 = 1_000,
};

// ============================================================================
// Shutdown Manager
// ============================================================================

pub const ShutdownManager = struct {
    allocator: Allocator,
    config: ShutdownConfig,
    phase: std.atomic.Value(u32),
    active_connections: std.atomic.Value(u64),
    active_requests: std.atomic.Value(u64),
    shutdown_requested_at: std.atomic.Value(i128),
    startup_time: i128,
    is_healthy: std.atomic.Value(u32),
    is_ready: std.atomic.Value(u32),

    // Global instance for signal handler
    var global_instance: ?*ShutdownManager = null;

    pub fn init(allocator: Allocator, config: ShutdownConfig) ShutdownManager {
        return .{
            .allocator = allocator,
            .config = config,
            .phase = std.atomic.Value(u32).init(@intFromEnum(ShutdownPhase.running)),
            .active_connections = std.atomic.Value(u64).init(0),
            .active_requests = std.atomic.Value(u64).init(0),
            .shutdown_requested_at = std.atomic.Value(i128).init(0),
            .startup_time = std.time.nanoTimestamp(),
            .is_healthy = std.atomic.Value(u32).init(1),
            .is_ready = std.atomic.Value(u32).init(0),
        };
    }

    /// Install signal handlers for SIGTERM and SIGINT
    pub fn installSignalHandlers(self: *ShutdownManager) !void {
        global_instance = self;
        const sa = posix.Sigaction{
            .handler = .{ .handler = signalHandler },
            .mask = posix.empty_sigset,
            .flags = 0,
        };
        try posix.sigaction(posix.SIG.TERM, &sa, null);
        try posix.sigaction(posix.SIG.INT, &sa, null);
    }

    fn signalHandler(sig: i32) callconv(.C) void {
        _ = sig;
        if (global_instance) |instance| {
            instance.phase.store(@intFromEnum(ShutdownPhase.draining), .release);
            instance.shutdown_requested_at.store(std.time.nanoTimestamp(), .release);
        }
    }

    // ====================================================================
    // Connection/Request Tracking
    // ====================================================================

    pub fn trackConnectionOpen(self: *ShutdownManager) void {
        _ = self.active_connections.fetchAdd(1, .monotonic);
    }

    pub fn trackConnectionClose(self: *ShutdownManager) void {
        _ = self.active_connections.fetchSub(1, .monotonic);
    }

    pub fn trackRequestStart(self: *ShutdownManager) bool {
        // Reject if draining
        const phase: ShutdownPhase = @enumFromInt(self.phase.load(.acquire));
        if (phase != .running) return false;
        _ = self.active_requests.fetchAdd(1, .monotonic);
        return true;
    }

    pub fn trackRequestEnd(self: *ShutdownManager) void {
        _ = self.active_requests.fetchSub(1, .monotonic);
    }

    // ====================================================================
    // Health Probes (Kubernetes)
    // ====================================================================

    pub fn setReady(self: *ShutdownManager, ready: bool) void {
        self.is_ready.store(if (ready) 1 else 0, .release);
    }

    pub fn setHealthy(self: *ShutdownManager, healthy: bool) void {
        self.is_healthy.store(if (healthy) 1 else 0, .release);
    }

    /// Startup probe: returns true once server has started
    pub fn isStarted(self: *const ShutdownManager) bool {
        return self.startup_time > 0;
    }

    /// Readiness probe: returns true when ready to accept traffic
    pub fn isReady(self: *const ShutdownManager) bool {
        const phase: ShutdownPhase = @enumFromInt(self.phase.load(.acquire));
        return phase == .running and self.is_ready.load(.acquire) == 1;
    }

    /// Liveness probe: returns true when server is alive and healthy
    pub fn isLive(self: *const ShutdownManager) bool {
        const phase: ShutdownPhase = @enumFromInt(self.phase.load(.acquire));
        return (phase == .running or phase == .draining) and self.is_healthy.load(.acquire) == 1;
    }

    pub fn getPhase(self: *const ShutdownManager) ShutdownPhase {
        return @enumFromInt(self.phase.load(.acquire));
    }

    pub fn getActiveConnections(self: *const ShutdownManager) u64 {
        return self.active_connections.load(.monotonic);
    }

    pub fn getActiveRequests(self: *const ShutdownManager) u64 {
        return self.active_requests.load(.monotonic);
    }

    // ====================================================================
    // Wait-for-drain loop (call from main after signal)
    // ====================================================================

    /// Block until all in-flight requests complete or timeout expires.
    /// Returns true if drained cleanly, false if timed out.
    pub fn waitForDrain(self: *ShutdownManager) bool {
        const drain_start = std.time.nanoTimestamp();
        const timeout_ns: i128 = @as(i128, @intCast(self.config.drain_timeout_ms)) * 1_000_000;

        while (self.active_requests.load(.acquire) > 0) {
            const elapsed = std.time.nanoTimestamp() - drain_start;
            if (elapsed > timeout_ns) {
                self.phase.store(@intFromEnum(ShutdownPhase.closing), .release);
                std.log.warn("Drain timeout after {d}ms, {d} requests still active", .{
                    self.config.drain_timeout_ms, self.active_requests.load(.acquire),
                });
                return false;
            }
            std.Thread.sleep(10_000_000); // 10ms poll
        }

        self.phase.store(@intFromEnum(ShutdownPhase.stopped), .release);
        std.log.info("Graceful shutdown complete — all requests drained", .{});
        return true;
    }

    /// Get uptime in seconds since server start
    pub fn uptimeSeconds(self: *const ShutdownManager) u64 {
        const now = std.time.nanoTimestamp();
        const elapsed = now - self.startup_time;
        if (elapsed < 0) return 0;
        return @intCast(@divTrunc(elapsed, 1_000_000_000));
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ShutdownManager init" {
    const alloc = std.testing.allocator;
    const mgr = ShutdownManager.init(alloc, .{});
    try std.testing.expectEqual(ShutdownPhase.running, mgr.getPhase());
    try std.testing.expectEqual(@as(u64, 0), mgr.getActiveConnections());
    try std.testing.expectEqual(@as(u64, 0), mgr.getActiveRequests());
}

test "ShutdownManager health probes" {
    const alloc = std.testing.allocator;
    var mgr = ShutdownManager.init(alloc, .{});
    try std.testing.expect(mgr.isStarted());
    try std.testing.expect(!mgr.isReady()); // not ready until setReady
    try std.testing.expect(mgr.isLive()); // live from start
    mgr.setReady(true);
    try std.testing.expect(mgr.isReady());
}

test "ShutdownManager connection tracking" {
    const alloc = std.testing.allocator;
    var mgr = ShutdownManager.init(alloc, .{});
    mgr.trackConnectionOpen();
    mgr.trackConnectionOpen();
    try std.testing.expectEqual(@as(u64, 2), mgr.getActiveConnections());
    mgr.trackConnectionClose();
    try std.testing.expectEqual(@as(u64, 1), mgr.getActiveConnections());
}

test "ShutdownManager request tracking rejects during drain" {
    const alloc = std.testing.allocator;
    var mgr = ShutdownManager.init(alloc, .{});
    try std.testing.expect(mgr.trackRequestStart()); // accept in running
    mgr.trackRequestEnd();
    // Simulate drain
    mgr.phase.store(@intFromEnum(ShutdownPhase.draining), .release);
    try std.testing.expect(!mgr.trackRequestStart()); // reject in draining
}

test "ShutdownManager waitForDrain immediate" {
    const alloc = std.testing.allocator;
    var mgr = ShutdownManager.init(alloc, .{ .drain_timeout_ms = 100 });
    // No active requests — should drain immediately
    const result = mgr.waitForDrain();
    try std.testing.expect(result);
    try std.testing.expectEqual(ShutdownPhase.stopped, mgr.getPhase());
}

test "ShutdownManager readiness goes false during drain" {
    const alloc = std.testing.allocator;
    var mgr = ShutdownManager.init(alloc, .{});
    mgr.setReady(true);
    try std.testing.expect(mgr.isReady());
    mgr.phase.store(@intFromEnum(ShutdownPhase.draining), .release);
    try std.testing.expect(!mgr.isReady());
    try std.testing.expect(mgr.isLive()); // still live during drain
}
