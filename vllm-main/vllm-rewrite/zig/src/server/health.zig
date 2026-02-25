//! Health Check System
//!
//! Provides comprehensive health monitoring for the vLLM service.
//! Supports Kubernetes-style probes and detailed component health.
//!
//! Endpoints:
//! - /health - Simple liveness check
//! - /health/live - Kubernetes liveness probe
//! - /health/ready - Kubernetes readiness probe
//! - /health/startup - Kubernetes startup probe
//! - /health/detailed - Detailed component status

const std = @import("std");
const log = @import("../utils/logging.zig");
const errors = @import("../utils/errors.zig");

// ==============================================
// Health Status
// ==============================================

/// Overall health status
pub const HealthStatus = enum {
    healthy,
    degraded,
    unhealthy,
    
    pub fn toString(self: HealthStatus) []const u8 {
        return switch (self) {
            .healthy => "healthy",
            .degraded => "degraded",
            .unhealthy => "unhealthy",
        };
    }
    
    pub fn httpStatus(self: HealthStatus) u16 {
        return switch (self) {
            .healthy => 200,
            .degraded => 200,  // Still serving, just degraded
            .unhealthy => 503,
        };
    }
};

/// Component health status
pub const ComponentHealth = struct {
    name: []const u8,
    status: HealthStatus,
    message: ?[]const u8 = null,
    latency_ms: ?u64 = null,
    last_check: i64,
    
    pub fn toJson(self: ComponentHealth, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        const writer = buffer.writer();
        
        try writer.print(
            \\{{"name":"{s}","status":"{s}"
        , .{ self.name, self.status.toString() });
        
        if (self.message) |msg| {
            try writer.print(",\"message\":\"{s}\"", .{msg});
        }
        
        if (self.latency_ms) |lat| {
            try writer.print(",\"latency_ms\":{d}", .{lat});
        }
        
        try writer.print(",\"last_check\":{d}}}", .{self.last_check});
        
        return buffer.toOwnedSlice();
    }
};

// ==============================================
// Health Check Interface
// ==============================================

/// Interface for health-checkable components
pub const HealthChecker = struct {
    name: []const u8,
    checkFn: *const fn (*anyopaque) ComponentHealth,
    context: *anyopaque,
    
    pub fn check(self: *HealthChecker) ComponentHealth {
        return self.checkFn(self.context);
    }
};

// ==============================================
// Health Monitor
// ==============================================

/// Central health monitoring system
pub const HealthMonitor = struct {
    allocator: std.mem.Allocator,
    
    /// Registered health checkers
    checkers: std.ArrayList(HealthChecker),
    
    /// Cached component health status
    component_status: std.StringHashMap(ComponentHealth),
    
    /// Service start time
    start_time: i64,
    
    /// Is service ready to accept traffic
    ready: bool = false,
    
    /// Is service alive
    alive: bool = true,
    
    /// Startup complete
    startup_complete: bool = false,
    
    /// Mutex for thread safety
    mutex: std.Thread.Mutex = .{},
    
    pub fn init(allocator: std.mem.Allocator) HealthMonitor {
        return HealthMonitor{
            .allocator = allocator,
            .checkers = std.ArrayList(HealthChecker).init(allocator),
            .component_status = std.StringHashMap(ComponentHealth).init(allocator),
            .start_time = std.time.timestamp(),
        };
    }
    
    pub fn deinit(self: *HealthMonitor) void {
        self.checkers.deinit();
        self.component_status.deinit();
    }
    
    /// Register a health checker
    pub fn register(self: *HealthMonitor, checker: HealthChecker) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.checkers.append(checker);
        log.info("Registered health checker: {s}", .{checker.name});
    }
    
    /// Run all health checks
    pub fn runChecks(self: *HealthMonitor) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.checkers.items) |*checker| {
            const health = checker.check();
            self.component_status.put(health.name, health) catch continue;
        }
    }
    
    /// Get overall health status
    pub fn getOverallStatus(self: *HealthMonitor) HealthStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var worst_status = HealthStatus.healthy;
        
        var it = self.component_status.valueIterator();
        while (it.next()) |health| {
            if (@intFromEnum(health.status) > @intFromEnum(worst_status)) {
                worst_status = health.status;
            }
        }
        
        return worst_status;
    }
    
    /// Mark service as ready
    pub fn setReady(self: *HealthMonitor, ready: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ready = ready;
        log.info("Service ready state: {}", .{ready});
    }
    
    /// Mark startup as complete
    pub fn setStartupComplete(self: *HealthMonitor) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.startup_complete = true;
        log.info("Service startup complete", .{});
    }
    
    /// Check liveness
    pub fn isAlive(self: *HealthMonitor) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.alive;
    }
    
    /// Check readiness
    pub fn isReady(self: *HealthMonitor) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.ready and self.getOverallStatusUnlocked() != .unhealthy;
    }
    
    /// Check startup
    pub fn isStartupComplete(self: *HealthMonitor) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.startup_complete;
    }
    
    fn getOverallStatusUnlocked(self: *HealthMonitor) HealthStatus {
        var worst_status = HealthStatus.healthy;
        
        var it = self.component_status.valueIterator();
        while (it.next()) |health| {
            if (@intFromEnum(health.status) > @intFromEnum(worst_status)) {
                worst_status = health.status;
            }
        }
        
        return worst_status;
    }
    
    /// Get uptime in seconds
    pub fn getUptime(self: *HealthMonitor) i64 {
        return std.time.timestamp() - self.start_time;
    }
    
    /// Generate detailed health response
    pub fn getDetailedHealth(self: *HealthMonitor) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var buffer = std.ArrayList(u8).init(self.allocator);
        const writer = buffer.writer();
        
        const overall = self.getOverallStatusUnlocked();
        
        try writer.print(
            \\{{"status":"{s}","uptime_seconds":{d},"components":[
        , .{ overall.toString(), self.getUptime() });
        
        var first = true;
        var it = self.component_status.valueIterator();
        while (it.next()) |health| {
            if (!first) try writer.writeByte(',');
            first = false;
            
            const json = try health.toJson(self.allocator);
            defer self.allocator.free(json);
            try writer.writeAll(json);
        }
        
        try writer.writeAll("]}");
        
        return buffer.toOwnedSlice();
    }
};

// ==============================================
// Built-in Health Checkers
// ==============================================

/// Model health checker
pub const ModelHealthChecker = struct {
    model_loaded: bool = false,
    last_inference_time: i64 = 0,
    inference_count: u64 = 0,
    error_count: u64 = 0,
    
    pub fn check(self: *ModelHealthChecker) ComponentHealth {
        const now = std.time.timestamp();
        
        if (!self.model_loaded) {
            return ComponentHealth{
                .name = "model",
                .status = .unhealthy,
                .message = "Model not loaded",
                .last_check = now,
            };
        }
        
        // Check error rate
        if (self.inference_count > 0) {
            const error_rate = @as(f64, @floatFromInt(self.error_count)) /
                @as(f64, @floatFromInt(self.inference_count));
            
            if (error_rate > 0.5) {
                return ComponentHealth{
                    .name = "model",
                    .status = .unhealthy,
                    .message = "High error rate",
                    .last_check = now,
                };
            } else if (error_rate > 0.1) {
                return ComponentHealth{
                    .name = "model",
                    .status = .degraded,
                    .message = "Elevated error rate",
                    .last_check = now,
                };
            }
        }
        
        return ComponentHealth{
            .name = "model",
            .status = .healthy,
            .last_check = now,
        };
    }
    
    pub fn recordInference(self: *ModelHealthChecker, success: bool) void {
        self.inference_count += 1;
        self.last_inference_time = std.time.timestamp();
        if (!success) {
            self.error_count += 1;
        }
    }
};

/// Memory health checker
pub const MemoryHealthChecker = struct {
    total_memory: u64,
    used_memory: u64 = 0,
    warning_threshold: f64 = 0.8,
    critical_threshold: f64 = 0.95,
    
    pub fn init(total_memory: u64) MemoryHealthChecker {
        return MemoryHealthChecker{
            .total_memory = total_memory,
        };
    }
    
    pub fn check(self: *MemoryHealthChecker) ComponentHealth {
        const now = std.time.timestamp();
        const usage = @as(f64, @floatFromInt(self.used_memory)) /
            @as(f64, @floatFromInt(self.total_memory));
        
        if (usage >= self.critical_threshold) {
            return ComponentHealth{
                .name = "memory",
                .status = .unhealthy,
                .message = "Critical memory pressure",
                .last_check = now,
            };
        } else if (usage >= self.warning_threshold) {
            return ComponentHealth{
                .name = "memory",
                .status = .degraded,
                .message = "High memory usage",
                .last_check = now,
            };
        }
        
        return ComponentHealth{
            .name = "memory",
            .status = .healthy,
            .last_check = now,
        };
    }
    
    pub fn updateUsage(self: *MemoryHealthChecker, used: u64) void {
        self.used_memory = used;
    }
};

/// GPU health checker
pub const GpuHealthChecker = struct {
    gpu_available: bool = false,
    gpu_memory_total: u64 = 0,
    gpu_memory_used: u64 = 0,
    temperature: f32 = 0,
    utilization: f32 = 0,
    
    pub fn check(self: *GpuHealthChecker) ComponentHealth {
        const now = std.time.timestamp();
        
        if (!self.gpu_available) {
            return ComponentHealth{
                .name = "gpu",
                .status = .unhealthy,
                .message = "GPU not available",
                .last_check = now,
            };
        }
        
        // Check temperature
        if (self.temperature > 90.0) {
            return ComponentHealth{
                .name = "gpu",
                .status = .unhealthy,
                .message = "GPU overheating",
                .last_check = now,
            };
        } else if (self.temperature > 80.0) {
            return ComponentHealth{
                .name = "gpu",
                .status = .degraded,
                .message = "GPU temperature elevated",
                .last_check = now,
            };
        }
        
        // Check memory
        if (self.gpu_memory_total > 0) {
            const usage = @as(f64, @floatFromInt(self.gpu_memory_used)) /
                @as(f64, @floatFromInt(self.gpu_memory_total));
            
            if (usage > 0.95) {
                return ComponentHealth{
                    .name = "gpu",
                    .status = .unhealthy,
                    .message = "GPU memory exhausted",
                    .last_check = now,
                };
            }
        }
        
        return ComponentHealth{
            .name = "gpu",
            .status = .healthy,
            .last_check = now,
        };
    }
};

/// Queue health checker
pub const QueueHealthChecker = struct {
    queue_size: u64 = 0,
    max_queue_size: u64 = 1000,
    warning_threshold: f64 = 0.7,
    
    pub fn check(self: *QueueHealthChecker) ComponentHealth {
        const now = std.time.timestamp();
        const usage = @as(f64, @floatFromInt(self.queue_size)) /
            @as(f64, @floatFromInt(self.max_queue_size));
        
        if (usage >= 1.0) {
            return ComponentHealth{
                .name = "queue",
                .status = .unhealthy,
                .message = "Queue full",
                .last_check = now,
            };
        } else if (usage >= self.warning_threshold) {
            return ComponentHealth{
                .name = "queue",
                .status = .degraded,
                .message = "Queue filling up",
                .last_check = now,
            };
        }
        
        return ComponentHealth{
            .name = "queue",
            .status = .healthy,
            .last_check = now,
        };
    }
};

// ==============================================
// HTTP Health Handlers
// ==============================================

/// HTTP handler for health endpoints
pub const HealthHandler = struct {
    monitor: *HealthMonitor,
    
    pub fn init(monitor: *HealthMonitor) HealthHandler {
        return HealthHandler{ .monitor = monitor };
    }
    
    /// Handle /health request
    pub fn handleHealth(self: *HealthHandler) HttpResponse {
        const status = self.monitor.getOverallStatus();
        return HttpResponse{
            .status = status.httpStatus(),
            .body = status.toString(),
        };
    }
    
    /// Handle /health/live request
    pub fn handleLiveness(self: *HealthHandler) HttpResponse {
        if (self.monitor.isAlive()) {
            return HttpResponse{ .status = 200, .body = "OK" };
        }
        return HttpResponse{ .status = 503, .body = "Service not alive" };
    }
    
    /// Handle /health/ready request
    pub fn handleReadiness(self: *HealthHandler) HttpResponse {
        if (self.monitor.isReady()) {
            return HttpResponse{ .status = 200, .body = "OK" };
        }
        return HttpResponse{ .status = 503, .body = "Service not ready" };
    }
    
    /// Handle /health/startup request
    pub fn handleStartup(self: *HealthHandler) HttpResponse {
        if (self.monitor.isStartupComplete()) {
            return HttpResponse{ .status = 200, .body = "OK" };
        }
        return HttpResponse{ .status = 503, .body = "Startup not complete" };
    }
    
    /// Handle /health/detailed request
    pub fn handleDetailed(self: *HealthHandler) !HttpResponse {
        const body = try self.monitor.getDetailedHealth();
        return HttpResponse{
            .status = self.monitor.getOverallStatus().httpStatus(),
            .body = body,
            .content_type = "application/json",
        };
    }
};

/// Simple HTTP response structure
pub const HttpResponse = struct {
    status: u16,
    body: []const u8,
    content_type: []const u8 = "text/plain",
};

// ==============================================
// Tests
// ==============================================

test "HealthMonitor basic operations" {
    const allocator = std.testing.allocator;
    var monitor = HealthMonitor.init(allocator);
    defer monitor.deinit();
    
    try std.testing.expect(!monitor.isReady());
    monitor.setReady(true);
    try std.testing.expect(monitor.isReady());
}

test "MemoryHealthChecker thresholds" {
    var checker = MemoryHealthChecker.init(1000);
    
    // Low usage
    checker.updateUsage(500);
    try std.testing.expectEqual(HealthStatus.healthy, checker.check().status);
    
    // High usage
    checker.updateUsage(850);
    try std.testing.expectEqual(HealthStatus.degraded, checker.check().status);
    
    // Critical usage
    checker.updateUsage(960);
    try std.testing.expectEqual(HealthStatus.unhealthy, checker.check().status);
}