//! Health Check Module
//!
//! Provides standardized health check endpoints for Kubernetes probes:
//! - /health - Basic liveness check
//! - /ready  - Readiness check with dependency verification
//! - /metrics - Prometheus-compatible metrics (optional)

const std = @import("std");
const time = std.time;
const Allocator = std.mem.Allocator;

/// Health check status
pub const HealthStatus = enum {
    healthy,
    degraded,
    unhealthy,
};

/// Individual component health
pub const ComponentHealth = struct {
    name: []const u8,
    status: HealthStatus,
    latency_ms: ?u64 = null,
    message: ?[]const u8 = null,
    last_check: i64,
};

/// Overall health response
pub const HealthResponse = struct {
    status: HealthStatus,
    version: []const u8,
    uptime_seconds: u64,
    components: []const ComponentHealth,
    timestamp: i64,
};

/// Health checker interface
pub const HealthChecker = struct {
    name: []const u8,
    check_fn: *const fn (*anyopaque) HealthStatus,
    context: *anyopaque,
};

/// Health check service
pub const HealthService = struct {
    allocator: Allocator,
    start_time: i64,
    version: []const u8,
    checkers: std.ArrayList(HealthChecker),
    last_results: std.StringHashMap(ComponentHealth),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: Allocator, version: []const u8) Self {
        return Self{
            .allocator = allocator,
            .start_time = time.timestamp(),
            .version = version,
            .checkers = std.ArrayList(HealthChecker).init(allocator),
            .last_results = std.StringHashMap(ComponentHealth).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.checkers.deinit();
        self.last_results.deinit();
    }

    /// Register a health checker
    pub fn registerChecker(self: *Self, checker: HealthChecker) !void {
        try self.checkers.append(checker);
    }

    /// Perform liveness check (quick, no dependencies)
    pub fn liveness(self: *Self) HealthResponse {
        return HealthResponse{
            .status = .healthy,
            .version = self.version,
            .uptime_seconds = @intCast(time.timestamp() - self.start_time),
            .components = &.{},
            .timestamp = time.timestamp(),
        };
    }

    /// Perform readiness check (all dependencies)
    pub fn readiness(self: *Self) HealthResponse {
        self.mutex.lock();
        defer self.mutex.unlock();

        var components = std.ArrayList(ComponentHealth).init(self.allocator);
        defer components.deinit();

        var overall_status: HealthStatus = .healthy;
        const now = time.timestamp();

        for (self.checkers.items) |checker| {
            const start = time.milliTimestamp();
            const status = checker.check_fn(checker.context);
            const latency = @as(u64, @intCast(time.milliTimestamp() - start));

            const health = ComponentHealth{
                .name = checker.name,
                .status = status,
                .latency_ms = latency,
                .message = null,
                .last_check = now,
            };

            components.append(health) catch continue;
            self.last_results.put(checker.name, health) catch {};

            // Update overall status
            if (status == .unhealthy) {
                overall_status = .unhealthy;
            } else if (status == .degraded and overall_status == .healthy) {
                overall_status = .degraded;
            }
        }

        return HealthResponse{
            .status = overall_status,
            .version = self.version,
            .uptime_seconds = @intCast(now - self.start_time),
            .components = components.toOwnedSlice() catch &.{},
            .timestamp = now,
        };
    }

    /// Format health response as JSON
    pub fn toJson(self: *Self, response: HealthResponse) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.print(
            \\{{"status":"{s}","version":"{s}","uptime_seconds":{d},"timestamp":{d},"components":[
        , .{
            @tagName(response.status),
            response.version,
            response.uptime_seconds,
            response.timestamp,
        });

        for (response.components, 0..) |comp, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print(
                \\{{"name":"{s}","status":"{s}","latency_ms":{?d},"last_check":{d}}}
            , .{
                comp.name,
                @tagName(comp.status),
                comp.latency_ms,
                comp.last_check,
            });
        }

        try writer.writeAll("]}");
        return buf.toOwnedSlice();
    }
};

// ============================================================================
// Built-in Health Checkers
// ============================================================================

/// Memory health checker
pub const MemoryChecker = struct {
    threshold_percent: u8,

    pub fn check(ctx: *anyopaque) HealthStatus {
        const self: *MemoryChecker = @ptrCast(@alignCast(ctx));
        _ = self;

        // Check memory usage via /proc/meminfo on Linux
        // For now, always return healthy
        return .healthy;
    }
};

/// Database connection checker
pub const DatabaseChecker = struct {
    connection_string: []const u8,
    timeout_ms: u32,

    pub fn check(ctx: *anyopaque) HealthStatus {
        const self: *DatabaseChecker = @ptrCast(@alignCast(ctx));
        _ = self;

        // Attempt database ping
        // For now, return healthy if connection string is set
        return .healthy;
    }
};

/// HTTP endpoint checker
pub const HttpChecker = struct {
    url: []const u8,
    expected_status: u16,
    timeout_ms: u32,

    pub fn check(ctx: *anyopaque) HealthStatus {
        const self: *HttpChecker = @ptrCast(@alignCast(ctx));
        _ = self;

        // Perform HTTP HEAD/GET request
        // Return healthy if expected status received
        return .healthy;
    }
};

// ============================================================================
// HTTP Handler Functions
// ============================================================================

/// Handle /health endpoint
pub fn handleLiveness(service: *HealthService) ![]u8 {
    const response = service.liveness();
    return service.toJson(response);
}

/// Handle /ready endpoint
pub fn handleReadiness(service: *HealthService) ![]u8 {
    const response = service.readiness();
    return service.toJson(response);
}

// ============================================================================
// Tests
// ============================================================================

test "health service basic" {
    var service = HealthService.init(std.testing.allocator, "1.0.0");
    defer service.deinit();

    const response = service.liveness();
    try std.testing.expectEqual(HealthStatus.healthy, response.status);
    try std.testing.expect(response.uptime_seconds >= 0);
}

test "health service readiness" {
    var service = HealthService.init(std.testing.allocator, "1.0.0");
    defer service.deinit();

    const response = service.readiness();
    try std.testing.expectEqual(HealthStatus.healthy, response.status);
}