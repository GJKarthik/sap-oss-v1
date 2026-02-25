//! Service Lifecycle Management
//!
//! Provides graceful startup and shutdown for the vLLM service.
//! Handles signal trapping, drain period, and resource cleanup.
//!
//! Features:
//! - Signal handling (SIGTERM, SIGINT)
//! - Graceful shutdown with drain period
//! - Request draining before shutdown
//! - Resource cleanup hooks
//! - Startup/shutdown hooks

const std = @import("std");
const log = @import("../utils/logging.zig");
const health = @import("health.zig");

// ==============================================
// Lifecycle State
// ==============================================

/// Service lifecycle state
pub const LifecycleState = enum {
    /// Service is initializing
    starting,
    
    /// Service is running and accepting requests
    running,
    
    /// Service is draining (not accepting new requests)
    draining,
    
    /// Service is shutting down
    stopping,
    
    /// Service has stopped
    stopped,
    
    pub fn toString(self: LifecycleState) []const u8 {
        return switch (self) {
            .starting => "starting",
            .running => "running",
            .draining => "draining",
            .stopping => "stopping",
            .stopped => "stopped",
        };
    }
};

// ==============================================
// Shutdown Configuration
// ==============================================

/// Configuration for graceful shutdown
pub const ShutdownConfig = struct {
    /// Time to wait for requests to drain (ms)
    drain_timeout_ms: u64 = 30000,
    
    /// Interval to check if requests are drained (ms)
    drain_check_interval_ms: u64 = 100,
    
    /// Time to wait for cleanup hooks (ms)
    cleanup_timeout_ms: u64 = 10000,
    
    /// Force shutdown after this time (ms)
    force_shutdown_timeout_ms: u64 = 60000,
    
    /// Enable graceful shutdown
    graceful: bool = true,
};

// ==============================================
// Lifecycle Hook
// ==============================================

/// Hook function type
pub const HookFn = *const fn (*anyopaque) anyerror!void;

/// Lifecycle hook
pub const LifecycleHook = struct {
    name: []const u8,
    hook: HookFn,
    context: *anyopaque,
    priority: u32 = 100,  // Lower = earlier
};

// ==============================================
// Lifecycle Manager
// ==============================================

/// Manages service lifecycle
pub const LifecycleManager = struct {
    allocator: std.mem.Allocator,
    config: ShutdownConfig,
    state: LifecycleState = .starting,
    
    /// Health monitor integration
    health_monitor: ?*health.HealthMonitor = null,
    
    /// Startup hooks
    startup_hooks: std.ArrayList(LifecycleHook),
    
    /// Shutdown hooks
    shutdown_hooks: std.ArrayList(LifecycleHook),
    
    /// Active request count
    active_requests: std.atomic.Value(u64),
    
    /// Shutdown signal received
    shutdown_requested: std.atomic.Value(bool),
    
    /// Mutex for state changes
    mutex: std.Thread.Mutex = .{},
    
    /// Condition variable for waiting
    condition: std.Thread.Condition = .{},
    
    pub fn init(allocator: std.mem.Allocator, config: ShutdownConfig) LifecycleManager {
        return LifecycleManager{
            .allocator = allocator,
            .config = config,
            .startup_hooks = std.ArrayList(LifecycleHook).init(allocator),
            .shutdown_hooks = std.ArrayList(LifecycleHook).init(allocator),
            .active_requests = std.atomic.Value(u64).init(0),
            .shutdown_requested = std.atomic.Value(bool).init(false),
        };
    }
    
    pub fn deinit(self: *LifecycleManager) void {
        self.startup_hooks.deinit();
        self.shutdown_hooks.deinit();
    }
    
    /// Set health monitor for integration
    pub fn setHealthMonitor(self: *LifecycleManager, monitor: *health.HealthMonitor) void {
        self.health_monitor = monitor;
    }
    
    /// Register a startup hook
    pub fn onStartup(self: *LifecycleManager, hook: LifecycleHook) !void {
        try self.startup_hooks.append(hook);
        log.debug("Registered startup hook: {s}", .{hook.name});
    }
    
    /// Register a shutdown hook
    pub fn onShutdown(self: *LifecycleManager, hook: LifecycleHook) !void {
        try self.shutdown_hooks.append(hook);
        log.debug("Registered shutdown hook: {s}", .{hook.name});
    }
    
    /// Start the service
    pub fn start(self: *LifecycleManager) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.state != .starting) {
            return error.InvalidState;
        }
        
        log.info("Starting service...", .{});
        
        // Sort hooks by priority
        std.mem.sort(LifecycleHook, self.startup_hooks.items, {}, struct {
            fn lessThan(_: void, a: LifecycleHook, b: LifecycleHook) bool {
                return a.priority < b.priority;
            }
        }.lessThan);
        
        // Run startup hooks
        for (self.startup_hooks.items) |hook| {
            log.info("Running startup hook: {s}", .{hook.name});
            hook.hook(hook.context) catch |err| {
                log.err("Startup hook '{s}' failed: {s}", .{ hook.name, @errorName(err) });
                return err;
            };
        }
        
        self.state = .running;
        
        if (self.health_monitor) |monitor| {
            monitor.setReady(true);
            monitor.setStartupComplete();
        }
        
        log.info("Service started successfully", .{});
    }
    
    /// Request graceful shutdown
    pub fn shutdown(self: *LifecycleManager) void {
        if (self.shutdown_requested.swap(true, .seq_cst)) {
            log.warn("Shutdown already requested", .{});
            return;
        }
        
        log.info("Shutdown requested", .{});
        
        // Start shutdown in separate thread to not block
        const thread = std.Thread.spawn(.{}, shutdownWorker, .{self}) catch {
            log.err("Failed to spawn shutdown thread", .{});
            return;
        };
        thread.detach();
    }
    
    fn shutdownWorker(self: *LifecycleManager) void {
        self.performShutdown() catch |err| {
            log.err("Shutdown failed: {s}", .{@errorName(err)});
        };
    }
    
    fn performShutdown(self: *LifecycleManager) !void {
        self.mutex.lock();
        
        if (self.state == .stopped or self.state == .stopping) {
            self.mutex.unlock();
            return;
        }
        
        // Transition to draining
        self.state = .draining;
        self.mutex.unlock();
        
        if (self.health_monitor) |monitor| {
            monitor.setReady(false);
        }
        
        log.info("Entering drain period...", .{});
        
        if (self.config.graceful) {
            try self.drainRequests();
        }
        
        // Transition to stopping
        self.mutex.lock();
        self.state = .stopping;
        self.mutex.unlock();
        
        log.info("Running shutdown hooks...", .{});
        
        // Sort hooks by priority (reverse for shutdown)
        std.mem.sort(LifecycleHook, self.shutdown_hooks.items, {}, struct {
            fn lessThan(_: void, a: LifecycleHook, b: LifecycleHook) bool {
                return a.priority > b.priority;  // Reverse order
            }
        }.lessThan);
        
        // Run shutdown hooks with timeout
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(self.config.cleanup_timeout_ms));
        
        for (self.shutdown_hooks.items) |hook| {
            if (std.time.milliTimestamp() > deadline) {
                log.warn("Shutdown hooks timeout, skipping remaining", .{});
                break;
            }
            
            log.info("Running shutdown hook: {s}", .{hook.name});
            hook.hook(hook.context) catch |err| {
                log.err("Shutdown hook '{s}' failed: {s}", .{ hook.name, @errorName(err) });
                // Continue with other hooks
            };
        }
        
        // Final state
        self.mutex.lock();
        self.state = .stopped;
        self.mutex.unlock();
        
        log.info("Service stopped", .{});
        
        // Signal waiters
        self.condition.broadcast();
    }
    
    fn drainRequests(self: *LifecycleManager) !void {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(self.config.drain_timeout_ms));
        
        while (std.time.milliTimestamp() < deadline) {
            const active = self.active_requests.load(.seq_cst);
            
            if (active == 0) {
                log.info("All requests drained", .{});
                return;
            }
            
            log.debug("Waiting for {d} active requests to complete...", .{active});
            std.time.sleep(self.config.drain_check_interval_ms * std.time.ns_per_ms);
        }
        
        const remaining = self.active_requests.load(.seq_cst);
        log.warn("Drain timeout reached with {d} requests remaining", .{remaining});
    }
    
    /// Wait for shutdown to complete
    pub fn waitForShutdown(self: *LifecycleManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        while (self.state != .stopped) {
            self.condition.wait(&self.mutex);
        }
    }
    
    /// Check if service is accepting requests
    pub fn isAcceptingRequests(self: *LifecycleManager) bool {
        return self.state == .running;
    }
    
    /// Get current state
    pub fn getState(self: *LifecycleManager) LifecycleState {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state;
    }
    
    /// Increment active request count
    pub fn requestStarted(self: *LifecycleManager) void {
        _ = self.active_requests.fetchAdd(1, .seq_cst);
    }
    
    /// Decrement active request count
    pub fn requestCompleted(self: *LifecycleManager) void {
        _ = self.active_requests.fetchSub(1, .seq_cst);
    }
    
    /// Get active request count
    pub fn getActiveRequests(self: *LifecycleManager) u64 {
        return self.active_requests.load(.seq_cst);
    }
};

// ==============================================
// Signal Handler
// ==============================================

/// Global lifecycle manager for signal handler
var global_lifecycle: ?*LifecycleManager = null;

/// Signal handler function
fn signalHandler(sig: c_int) callconv(.C) void {
    const sig_name = switch (sig) {
        std.os.SIG.INT => "SIGINT",
        std.os.SIG.TERM => "SIGTERM",
        else => "UNKNOWN",
    };
    
    // Can't use log in signal handler, use direct write
    const msg = "Received signal: ";
    _ = std.os.write(std.os.STDERR_FILENO, msg) catch {};
    _ = std.os.write(std.os.STDERR_FILENO, sig_name) catch {};
    _ = std.os.write(std.os.STDERR_FILENO, "\n") catch {};
    
    if (global_lifecycle) |lifecycle| {
        lifecycle.shutdown();
    }
}

/// Install signal handlers
pub fn installSignalHandlers(lifecycle: *LifecycleManager) !void {
    global_lifecycle = lifecycle;
    
    // Install SIGTERM handler
    var term_action = std.os.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.os.empty_sigset,
        .flags = 0,
    };
    try std.os.sigaction(std.os.SIG.TERM, &term_action, null);
    
    // Install SIGINT handler
    var int_action = std.os.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.os.empty_sigset,
        .flags = 0,
    };
    try std.os.sigaction(std.os.SIG.INT, &int_action, null);
    
    log.info("Signal handlers installed", .{});
}

// ==============================================
// Request Guard
// ==============================================

/// RAII guard for request tracking
pub const RequestGuard = struct {
    lifecycle: *LifecycleManager,
    
    pub fn init(lifecycle: *LifecycleManager) ?RequestGuard {
        if (!lifecycle.isAcceptingRequests()) {
            return null;
        }
        lifecycle.requestStarted();
        return RequestGuard{ .lifecycle = lifecycle };
    }
    
    pub fn deinit(self: *RequestGuard) void {
        self.lifecycle.requestCompleted();
    }
};

// ==============================================
// Tests
// ==============================================

test "LifecycleManager state transitions" {
    const allocator = std.testing.allocator;
    var manager = LifecycleManager.init(allocator, .{});
    defer manager.deinit();
    
    try std.testing.expectEqual(LifecycleState.starting, manager.getState());
    
    try manager.start();
    try std.testing.expectEqual(LifecycleState.running, manager.getState());
    try std.testing.expect(manager.isAcceptingRequests());
}

test "LifecycleManager request tracking" {
    const allocator = std.testing.allocator;
    var manager = LifecycleManager.init(allocator, .{});
    defer manager.deinit();
    
    try manager.start();
    
    try std.testing.expectEqual(@as(u64, 0), manager.getActiveRequests());
    
    manager.requestStarted();
    try std.testing.expectEqual(@as(u64, 1), manager.getActiveRequests());
    
    manager.requestStarted();
    try std.testing.expectEqual(@as(u64, 2), manager.getActiveRequests());
    
    manager.requestCompleted();
    try std.testing.expectEqual(@as(u64, 1), manager.getActiveRequests());
}

test "RequestGuard automatic cleanup" {
    const allocator = std.testing.allocator;
    var manager = LifecycleManager.init(allocator, .{});
    defer manager.deinit();
    
    try manager.start();
    
    {
        var guard = RequestGuard.init(&manager);
        try std.testing.expect(guard != null);
        try std.testing.expectEqual(@as(u64, 1), manager.getActiveRequests());
        if (guard) |*g| g.deinit();
    }
    
    try std.testing.expectEqual(@as(u64, 0), manager.getActiveRequests());
}