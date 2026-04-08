//! ANWID Graceful Shutdown Handler
//! Drains in-flight requests before shutdown
//! Handles SIGTERM/SIGINT for Kubernetes pod termination

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.graceful_shutdown);

// ============================================================================
// Shutdown Configuration
// ============================================================================

pub const ShutdownConfig = struct {
    /// Maximum time to wait for in-flight requests to complete (ms)
    drain_timeout_ms: u64 = 30_000,
    /// Interval to check for remaining requests (ms)
    poll_interval_ms: u64 = 100,
    /// Enable health endpoint during shutdown (return 503)
    fail_health_on_shutdown: bool = true,
};

// ============================================================================
// Shutdown State
// ============================================================================

pub const ShutdownState = enum(u8) {
    /// Server is running normally
    running,
    /// Shutdown initiated, draining requests
    draining,
    /// Drain complete, shutting down
    shutdown,
};

// ============================================================================
// Graceful Shutdown Handler
// ============================================================================

pub const GracefulShutdown = struct {
    config: ShutdownConfig,
    state: std.atomic.Value(ShutdownState),
    
    // Request tracking
    requests_in_flight: std.atomic.Value(u64),
    
    // Timing
    shutdown_initiated_ms: std.atomic.Value(i64),
    
    // Callbacks
    on_drain_complete: ?*const fn () void,
    on_shutdown: ?*const fn () void,
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, config: ShutdownConfig) !*GracefulShutdown {
        const gs = try allocator.create(GracefulShutdown);
        
        gs.* = .{
            .config = config,
            .state = std.atomic.Value(ShutdownState).init(.running),
            .requests_in_flight = std.atomic.Value(u64).init(0),
            .shutdown_initiated_ms = std.atomic.Value(i64).init(0),
            .on_drain_complete = null,
            .on_shutdown = null,
            .allocator = allocator,
        };
        
        log.info("Graceful Shutdown handler initialized:", .{});
        log.info("  Drain timeout: {}ms", .{config.drain_timeout_ms});
        
        return gs;
    }
    
    pub fn deinit(self: *GracefulShutdown) void {
        log.info("Graceful Shutdown handler destroyed", .{});
        self.allocator.destroy(self);
    }
    
    /// Register callbacks
    pub fn setCallbacks(
        self: *GracefulShutdown,
        on_drain_complete: ?*const fn () void,
        on_shutdown: ?*const fn () void,
    ) void {
        self.on_drain_complete = on_drain_complete;
        self.on_shutdown = on_shutdown;
    }
    
    /// Check if server is accepting new requests
    pub fn isAcceptingRequests(self: *const GracefulShutdown) bool {
        return self.state.load(.acquire) == .running;
    }
    
    /// Check if server should return healthy
    pub fn isHealthy(self: *const GracefulShutdown) bool {
        const state = self.state.load(.acquire);
        if (self.config.fail_health_on_shutdown and state != .running) {
            return false;
        }
        return true;
    }
    
    /// Call when starting a request
    pub fn requestStarted(self: *GracefulShutdown) bool {
        if (self.state.load(.acquire) != .running) {
            return false; // Reject new requests during shutdown
        }
        _ = self.requests_in_flight.fetchAdd(1, .monotonic);
        return true;
    }
    
    /// Call when a request completes
    pub fn requestCompleted(self: *GracefulShutdown) void {
        const prev = self.requests_in_flight.fetchSub(1, .monotonic);
        
        // Check if this was the last request during drain
        if (prev == 1 and self.state.load(.acquire) == .draining) {
            self.checkDrainComplete();
        }
    }
    
    /// Initiate graceful shutdown
    pub fn initiateShutdown(self: *GracefulShutdown) void {
        const old_state = self.state.swap(.draining, .acq_rel);
        
        if (old_state == .running) {
            const now = std.time.milliTimestamp();
            self.shutdown_initiated_ms.store(now, .release);
            
            log.warn("Graceful shutdown initiated", .{});
            log.info("  Requests in flight: {}", .{self.requests_in_flight.load(.acquire)});
            
            self.checkDrainComplete();
        }
    }
    
    /// Wait for shutdown to complete (blocking)
    pub fn waitForShutdown(self: *GracefulShutdown) void {
        const start = std.time.milliTimestamp();
        const timeout = @as(i64, @intCast(self.config.drain_timeout_ms));
        
        while (self.state.load(.acquire) == .draining) {
            const now = std.time.milliTimestamp();
            
            if (now - start >= timeout) {
                log.warn("Drain timeout reached, forcing shutdown", .{});
                log.warn("  Remaining requests: {}", .{self.requests_in_flight.load(.acquire)});
                self.forceShutdown();
                break;
            }
            
            // Log progress
            if (@mod(now - start, 5000) == 0 and (now - start) > 0) {
                log.info("Still draining... {} requests remaining", .{
                    self.requests_in_flight.load(.acquire),
                });
            }
            
            std.atomic.spinLoopHint();
        }
    }
    
    /// Check if drain is complete
    fn checkDrainComplete(self: *GracefulShutdown) void {
        if (self.requests_in_flight.load(.acquire) == 0) {
            self.state.store(.shutdown, .release);
            log.info("Drain complete, all requests finished", .{});
            
            if (self.on_drain_complete) |cb| cb();
            if (self.on_shutdown) |cb| cb();
        }
    }
    
    /// Force immediate shutdown
    pub fn forceShutdown(self: *GracefulShutdown) void {
        self.state.store(.shutdown, .release);
        log.warn("Forced shutdown", .{});
        
        if (self.on_shutdown) |cb| cb();
    }
    
    /// Get current state
    pub fn getState(self: *const GracefulShutdown) ShutdownState {
        return self.state.load(.acquire);
    }
    
    /// Get statistics
    pub fn getStats(self: *const GracefulShutdown) ShutdownStats {
        const initiated = self.shutdown_initiated_ms.load(.acquire);
        const now = std.time.milliTimestamp();
        
        return .{
            .state = self.state.load(.acquire),
            .requests_in_flight = self.requests_in_flight.load(.acquire),
            .drain_duration_ms = if (initiated > 0) @intCast(now - initiated) else 0,
        };
    }
};

pub const ShutdownStats = struct {
    state: ShutdownState,
    requests_in_flight: u64,
    drain_duration_ms: u64,
};

// ============================================================================
// Signal Handler (POSIX)
// ============================================================================

var global_shutdown: ?*GracefulShutdown = null;

pub fn installSignalHandlers(gs: *GracefulShutdown) !void {
    global_shutdown = gs;
    
    if (comptime builtin.os.tag != .windows) {
        const handler = struct {
            fn signalHandler(sig: c_int) callconv(.C) void {
                _ = sig;
                if (global_shutdown) |shutdown| {
                    shutdown.initiateShutdown();
                }
            }
        };
        
        var sa: std.posix.Sigaction = .{
            .handler = .{ .handler = handler.signalHandler },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        };
        
        // SIGTERM (Kubernetes pod termination)
        std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
        
        // SIGINT (Ctrl+C)
        std.posix.sigaction(std.posix.SIG.INT, &sa, null);
        
        log.info("Signal handlers installed (SIGTERM, SIGINT)", .{});
    }
}

// ============================================================================
// Tests
// ============================================================================

test "GracefulShutdown init and deinit" {
    const gs = try GracefulShutdown.init(std.testing.allocator, .{});
    defer gs.deinit();
    
    try std.testing.expectEqual(ShutdownState.running, gs.getState());
    try std.testing.expect(gs.isAcceptingRequests());
}

test "GracefulShutdown request tracking" {
    const gs = try GracefulShutdown.init(std.testing.allocator, .{});
    defer gs.deinit();
    
    try std.testing.expect(gs.requestStarted());
    try std.testing.expectEqual(@as(u64, 1), gs.requests_in_flight.load(.acquire));
    
    gs.requestCompleted();
    try std.testing.expectEqual(@as(u64, 0), gs.requests_in_flight.load(.acquire));
}

test "GracefulShutdown rejects requests during drain" {
    const gs = try GracefulShutdown.init(std.testing.allocator, .{});
    defer gs.deinit();
    
    gs.initiateShutdown();
    
    try std.testing.expect(!gs.isAcceptingRequests());
    try std.testing.expect(!gs.requestStarted());
}

test "GracefulShutdown completes when no requests" {
    const gs = try GracefulShutdown.init(std.testing.allocator, .{});
    defer gs.deinit();
    
    gs.initiateShutdown();
    
    // Should immediately complete since no requests in flight
    try std.testing.expectEqual(ShutdownState.shutdown, gs.getState());
}