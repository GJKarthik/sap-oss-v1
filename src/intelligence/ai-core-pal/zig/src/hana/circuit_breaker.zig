//! Circuit Breaker for HANA / external HTTP calls.
//!
//! States:
//!   Closed   — normal operation; failures are counted
//!   Open     — all calls fail-fast; re-tried after reset_timeout_s
//!   HalfOpen — one probe call is allowed; success → Closed, failure → Open
//!
//! Usage:
//!   var cb = CircuitBreaker.init(.{});
//!   if (!cb.allow()) return error.CircuitOpen;
//!   doCall() catch |err| { cb.recordFailure(); return err; };
//!   cb.recordSuccess();

const std = @import("std");

pub const State = enum { closed, open, half_open };

pub const Config = struct {
    /// Consecutive failures before opening the circuit.
    failure_threshold: u32 = 5,
    /// Seconds to wait in open state before moving to half-open.
    reset_timeout_s: i64 = 30,
    /// Half-open probe window in seconds (probe succeeds → close).
    half_open_timeout_s: i64 = 10,
};

pub const CircuitBreaker = struct {
    cfg: Config,
    state: State,
    failure_count: u32,
    last_failure_time: i64,
    last_probe_time: i64,

    pub fn init(cfg: Config) CircuitBreaker {
        return .{
            .cfg = cfg,
            .state = .closed,
            .failure_count = 0,
            .last_failure_time = 0,
            .last_probe_time = 0,
        };
    }

    /// Returns true if the call should be allowed to proceed.
    pub fn allow(self: *CircuitBreaker) bool {
        const now = std.time.timestamp();
        switch (self.state) {
            .closed => return true,
            .open => {
                if (now - self.last_failure_time >= self.cfg.reset_timeout_s) {
                    self.state = .half_open;
                    self.last_probe_time = now;
                    return true; // allow one probe
                }
                return false;
            },
            .half_open => {
                // Only allow a probe if the previous probe window has elapsed
                if (now - self.last_probe_time >= self.cfg.half_open_timeout_s) {
                    self.last_probe_time = now;
                    return true;
                }
                return false;
            },
        }
    }

    /// Record a successful call — resets the breaker to closed.
    pub fn recordSuccess(self: *CircuitBreaker) void {
        self.failure_count = 0;
        self.state = .closed;
    }

    /// Record a failed call — may trip the breaker to open.
    pub fn recordFailure(self: *CircuitBreaker) void {
        self.last_failure_time = std.time.timestamp();
        switch (self.state) {
            .closed => {
                self.failure_count += 1;
                if (self.failure_count >= self.cfg.failure_threshold) {
                    self.state = .open;
                    std.log.warn("[circuit_breaker] tripped OPEN after {d} failures", .{self.failure_count});
                }
            },
            .half_open => {
                // Probe failed — go back to open
                self.state = .open;
                std.log.warn("[circuit_breaker] probe failed, returning to OPEN", .{});
            },
            .open => {}, // already open
        }
    }

    pub fn isOpen(self: *const CircuitBreaker) bool {
        return self.state == .open;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "circuit breaker starts closed" {
    var cb = CircuitBreaker.init(.{});
    try std.testing.expect(cb.allow());
    try std.testing.expectEqual(State.closed, cb.state);
}

test "circuit breaker trips after threshold" {
    var cb = CircuitBreaker.init(.{ .failure_threshold = 3 });
    cb.recordFailure();
    cb.recordFailure();
    try std.testing.expectEqual(State.closed, cb.state);
    cb.recordFailure();
    try std.testing.expectEqual(State.open, cb.state);
    try std.testing.expect(!cb.allow());
}

test "circuit breaker resets on success" {
    var cb = CircuitBreaker.init(.{ .failure_threshold = 2 });
    cb.recordFailure();
    cb.recordFailure();
    try std.testing.expectEqual(State.open, cb.state);
    // Simulate time passing by manually backdating last_failure_time
    cb.last_failure_time = std.time.timestamp() - 60;
    try std.testing.expect(cb.allow()); // should move to half_open
    try std.testing.expectEqual(State.half_open, cb.state);
    cb.recordSuccess();
    try std.testing.expectEqual(State.closed, cb.state);
    try std.testing.expectEqual(@as(u32, 0), cb.failure_count);
}

test "half open probe failure returns to open" {
    var cb = CircuitBreaker.init(.{ .failure_threshold = 1 });
    cb.recordFailure();
    try std.testing.expectEqual(State.open, cb.state);
    cb.last_failure_time = std.time.timestamp() - 60;
    _ = cb.allow(); // moves to half_open
    cb.recordFailure();
    try std.testing.expectEqual(State.open, cb.state);
}
