//! ANWID Circuit Breaker
//! Implements circuit breaker pattern for NIM and external service calls
//! States: Closed (normal) → Open (failing) → Half-Open (testing)

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.circuit_breaker);

// ============================================================================
// Circuit Breaker Configuration
// ============================================================================

pub const CircuitBreakerConfig = struct {
    /// Number of failures before opening circuit
    failure_threshold: u32 = 5,
    /// Time to wait before trying half-open (milliseconds)
    reset_timeout_ms: u64 = 30_000,
    /// Number of successful calls in half-open before closing
    success_threshold: u32 = 3,
    /// Request timeout hint (milliseconds).
    /// NOTE: Not enforced by execute() — callers must implement their own
    /// timeout logic (e.g. via async I/O deadlines). This field exists so
    /// higher-level wrappers can read a consistent timeout value.
    request_timeout_ms: u64 = 10_000,
    /// Enable fallback on failure
    enable_fallback: bool = true,
};

// ============================================================================
// Circuit State
// ============================================================================

pub const CircuitState = enum(u8) {
    /// Circuit is closed, requests flow normally
    closed,
    /// Circuit is open, requests fail immediately
    open,
    /// Circuit is testing, limited requests allowed
    half_open,
};

// ============================================================================
// Circuit Breaker
// ============================================================================

pub const CircuitBreaker = struct {
    name: []const u8,
    config: CircuitBreakerConfig,
    state: std.atomic.Value(CircuitState),

    // Failure tracking
    consecutive_failures: std.atomic.Value(u32),
    consecutive_successes: std.atomic.Value(u32),

    // Timing
    last_failure_time_ms: std.atomic.Value(i64),
    last_state_change_ms: std.atomic.Value(i64),

    // Statistics
    total_requests: std.atomic.Value(u64),
    total_successes: std.atomic.Value(u64),
    total_failures: std.atomic.Value(u64),
    total_rejected: std.atomic.Value(u64),
    total_fallbacks: std.atomic.Value(u64),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, config: CircuitBreakerConfig) !*CircuitBreaker {
        const cb = try allocator.create(CircuitBreaker);

        cb.* = .{
            .name = name,
            .config = config,
            .state = std.atomic.Value(CircuitState).init(.closed),
            .consecutive_failures = std.atomic.Value(u32).init(0),
            .consecutive_successes = std.atomic.Value(u32).init(0),
            .last_failure_time_ms = std.atomic.Value(i64).init(0),
            .last_state_change_ms = std.atomic.Value(i64).init(std.time.milliTimestamp()),
            .total_requests = std.atomic.Value(u64).init(0),
            .total_successes = std.atomic.Value(u64).init(0),
            .total_failures = std.atomic.Value(u64).init(0),
            .total_rejected = std.atomic.Value(u64).init(0),
            .total_fallbacks = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };

        log.info("Circuit Breaker '{s}' initialized:", .{name});
        log.info("  Failure threshold: {}", .{config.failure_threshold});
        log.info("  Reset timeout: {}ms", .{config.reset_timeout_ms});

        return cb;
    }

    pub fn deinit(self: *CircuitBreaker) void {
        log.info("Circuit Breaker '{s}' destroyed", .{self.name});
        self.allocator.destroy(self);
    }

    /// Check if request should be allowed
    pub fn allowRequest(self: *CircuitBreaker) bool {
        const state = self.state.load(.acquire);

        switch (state) {
            .closed => return true,
            .open => {
                // Check if reset timeout has passed
                const now = std.time.milliTimestamp();
                const last_failure = self.last_failure_time_ms.load(.acquire);

                if (now - last_failure >= @as(i64, @intCast(self.config.reset_timeout_ms))) {
                    // Try CAS: only one thread wins the transition to half_open
                    if (self.state.cmpxchgStrong(.open, .half_open, .acq_rel, .acquire) == null) {
                        // We won the CAS - transition succeeded
                        self.last_state_change_ms.store(now, .release);
                        self.consecutive_failures.store(0, .release);
                        self.consecutive_successes.store(0, .release);
                        log.warn("Circuit '{s}' state change: open -> half_open", .{self.name});
                        return true;
                    }
                    // CAS failed - another thread already transitioned
                    // Check the new state
                    const current = self.state.load(.acquire);
                    return current == .half_open;
                }

                _ = self.total_rejected.fetchAdd(1, .monotonic);
                return false;
            },
            .half_open => {
                // Allow limited requests in half-open
                return true;
            },
        }
    }

    /// Record a successful call
    pub fn recordSuccess(self: *CircuitBreaker) void {
        _ = self.total_requests.fetchAdd(1, .monotonic);
        _ = self.total_successes.fetchAdd(1, .monotonic);

        const state = self.state.load(.acquire);

        switch (state) {
            .closed => {
                // Reset failure counter on success
                self.consecutive_failures.store(0, .release);
            },
            .half_open => {
                const successes = self.consecutive_successes.fetchAdd(1, .monotonic) + 1;

                if (successes >= self.config.success_threshold) {
                    // Enough successes, close the circuit via CAS
                    self.transitionTo(.half_open, .closed);
                }
            },
            .open => {},
        }
    }

    /// Record a failed call
    pub fn recordFailure(self: *CircuitBreaker) void {
        _ = self.total_requests.fetchAdd(1, .monotonic);
        _ = self.total_failures.fetchAdd(1, .monotonic);

        const now = std.time.milliTimestamp();
        self.last_failure_time_ms.store(now, .release);

        const state = self.state.load(.acquire);

        switch (state) {
            .closed => {
                const failures = self.consecutive_failures.fetchAdd(1, .monotonic) + 1;

                if (failures >= self.config.failure_threshold) {
                    // Too many failures, open the circuit via CAS
                    self.transitionTo(.closed, .open);
                }
            },
            .half_open => {
                // Any failure in half-open reopens the circuit via CAS
                self.transitionTo(.half_open, .open);
            },
            .open => {},
        }
    }

    /// Record a fallback execution
    pub fn recordFallback(self: *CircuitBreaker) void {
        _ = self.total_fallbacks.fetchAdd(1, .monotonic);
    }

    /// Transition to a new state (CAS-based, thread-safe)
    fn transitionTo(self: *CircuitBreaker, expected_state: CircuitState, new_state: CircuitState) void {
        // Use CAS to atomically transition only if we're in the expected state
        if (self.state.cmpxchgStrong(expected_state, new_state, .acq_rel, .acquire)) |_| {
            // CAS failed, another thread changed state first - that's OK
            return;
        }

        // CAS succeeded - we own this transition
        const now = std.time.milliTimestamp();
        self.last_state_change_ms.store(now, .release);

        // Reset counters on state change
        self.consecutive_failures.store(0, .release);
        self.consecutive_successes.store(0, .release);

        log.warn("Circuit '{s}' state change: {} -> {}", .{ self.name, expected_state, new_state });
    }

    /// Force open the circuit (for testing or manual intervention)
    pub fn forceOpen(self: *CircuitBreaker) void {
        self.state.store(.open, .release);
        self.last_failure_time_ms.store(std.time.milliTimestamp(), .release);
        self.last_state_change_ms.store(std.time.milliTimestamp(), .release);
        self.consecutive_failures.store(0, .release);
        self.consecutive_successes.store(0, .release);
        log.warn("Circuit '{s}' force opened", .{self.name});
    }

    /// Force close the circuit
    pub fn forceClose(self: *CircuitBreaker) void {
        self.state.store(.closed, .release);
        self.last_state_change_ms.store(std.time.milliTimestamp(), .release);
        self.consecutive_failures.store(0, .release);
        self.consecutive_successes.store(0, .release);
        log.info("Circuit '{s}' force closed", .{self.name});
    }

    /// Get current state
    pub fn getState(self: *const CircuitBreaker) CircuitState {
        return self.state.load(.acquire);
    }

    /// Get statistics
    pub fn getStats(self: *const CircuitBreaker) CircuitStats {
        return .{
            .name = self.name,
            .state = self.state.load(.acquire),
            .total_requests = self.total_requests.load(.acquire),
            .total_successes = self.total_successes.load(.acquire),
            .total_failures = self.total_failures.load(.acquire),
            .total_rejected = self.total_rejected.load(.acquire),
            .total_fallbacks = self.total_fallbacks.load(.acquire),
            .consecutive_failures = self.consecutive_failures.load(.acquire),
            .consecutive_successes = self.consecutive_successes.load(.acquire),
        };
    }
};

pub const CircuitStats = struct {
    name: []const u8,
    state: CircuitState,
    total_requests: u64,
    total_successes: u64,
    total_failures: u64,
    total_rejected: u64,
    total_fallbacks: u64,
    consecutive_failures: u32,
    consecutive_successes: u32,

    pub fn successRate(self: *const CircuitStats) f64 {
        if (self.total_requests == 0) return 1.0;
        return @as(f64, @floatFromInt(self.total_successes)) / @as(f64, @floatFromInt(self.total_requests));
    }
};

// ============================================================================
// Execute with Circuit Breaker
// ============================================================================

pub fn ExecutionResult(comptime T: type) type {
    return struct {
        value: ?T,
        from_fallback: bool,
        error_msg: ?[]const u8,
    };
}

/// Execute a function with circuit breaker protection
pub fn execute(
    comptime T: type,
    cb: *CircuitBreaker,
    func: anytype,
    args: anytype,
    fallback: ?fn () T,
) ExecutionResult(T) {
    if (!cb.allowRequest()) {
        // Circuit is open
        if (cb.config.enable_fallback) {
            if (fallback) |fb| {
                cb.recordFallback();
                return .{ .value = fb(), .from_fallback = true, .error_msg = "circuit open" };
            }
        }
        return .{ .value = null, .from_fallback = false, .error_msg = "circuit open" };
    }

    // Execute the function
    const result = @call(.auto, func, args) catch |err| {
        cb.recordFailure();

        if (cb.config.enable_fallback) {
            if (fallback) |fb| {
                cb.recordFallback();
                return .{ .value = fb(), .from_fallback = true, .error_msg = @errorName(err) };
            }
        }

        return .{ .value = null, .from_fallback = false, .error_msg = @errorName(err) };
    };

    cb.recordSuccess();
    return .{ .value = result, .from_fallback = false, .error_msg = null };
}

// ============================================================================
// Tests
// ============================================================================

test "CircuitBreaker init and deinit" {
    const cb = try CircuitBreaker.init(std.testing.allocator, "test", .{});
    defer cb.deinit();

    try std.testing.expectEqual(CircuitState.closed, cb.getState());
}

test "CircuitBreaker opens after threshold failures" {
    const cb = try CircuitBreaker.init(std.testing.allocator, "test", .{
        .failure_threshold = 3,
    });
    defer cb.deinit();

    try std.testing.expectEqual(CircuitState.closed, cb.getState());

    cb.recordFailure();
    cb.recordFailure();
    try std.testing.expectEqual(CircuitState.closed, cb.getState());

    cb.recordFailure();
    try std.testing.expectEqual(CircuitState.open, cb.getState());
}

test "CircuitBreaker rejects requests when open" {
    const cb = try CircuitBreaker.init(std.testing.allocator, "test", .{
        .failure_threshold = 1,
        .reset_timeout_ms = 60_000, // Long timeout
    });
    defer cb.deinit();

    cb.recordFailure();
    try std.testing.expectEqual(CircuitState.open, cb.getState());

    try std.testing.expect(!cb.allowRequest());
}

test "CircuitBreaker success resets failure count" {
    const cb = try CircuitBreaker.init(std.testing.allocator, "test", .{
        .failure_threshold = 3,
    });
    defer cb.deinit();

    cb.recordFailure();
    cb.recordFailure();
    cb.recordSuccess();

    try std.testing.expectEqual(CircuitState.closed, cb.getState());
    try std.testing.expectEqual(@as(u32, 0), cb.consecutive_failures.load(.acquire));
}

test "CircuitBreaker transition uses CAS" {
    const cb = try CircuitBreaker.init(std.testing.allocator, "cas-test", .{
        .failure_threshold = 1,
        .reset_timeout_ms = 0, // Immediate reset for testing
    });
    defer cb.deinit();

    // Open the circuit
    cb.recordFailure();
    try std.testing.expectEqual(CircuitState.open, cb.getState());

    // Allow request should transition to half_open via CAS
    const allowed = cb.allowRequest();
    try std.testing.expect(allowed);
    try std.testing.expectEqual(CircuitState.half_open, cb.getState());
}

test "execute succeeds through circuit breaker" {
    const cb = try CircuitBreaker.init(std.testing.allocator, "exec-ok", .{});
    defer cb.deinit();

    const result = execute(u32, cb, successFn, .{}, null);
    try std.testing.expectEqual(@as(?u32, 42), result.value);
    try std.testing.expect(!result.from_fallback);
    try std.testing.expect(result.error_msg == null);
    try std.testing.expectEqual(@as(u64, 1), cb.total_successes.load(.acquire));
}

test "execute falls back when circuit is open" {
    const cb = try CircuitBreaker.init(std.testing.allocator, "exec-fb", .{
        .failure_threshold = 1,
        .reset_timeout_ms = 60_000,
        .enable_fallback = true,
    });
    defer cb.deinit();

    // Open the circuit
    cb.recordFailure();
    try std.testing.expectEqual(CircuitState.open, cb.getState());

    const result = execute(u32, cb, successFn, .{}, fallbackFn);
    try std.testing.expectEqual(@as(?u32, 0), result.value);
    try std.testing.expect(result.from_fallback);
    try std.testing.expectEqual(@as(u64, 1), cb.total_fallbacks.load(.acquire));
}

test "half-open to closed after success threshold" {
    const cb = try CircuitBreaker.init(std.testing.allocator, "ho-close", .{
        .failure_threshold = 1,
        .success_threshold = 2,
        .reset_timeout_ms = 0,
    });
    defer cb.deinit();

    // Open the circuit
    cb.recordFailure();
    try std.testing.expectEqual(CircuitState.open, cb.getState());

    // Transition to half_open
    _ = cb.allowRequest();
    try std.testing.expectEqual(CircuitState.half_open, cb.getState());

    // Record enough successes to close
    cb.recordSuccess();
    cb.recordSuccess();
    try std.testing.expectEqual(CircuitState.closed, cb.getState());
}

// Test helpers
fn successFn() error{Fail}!u32 {
    return 42;
}

fn fallbackFn() u32 {
    return 0;
}