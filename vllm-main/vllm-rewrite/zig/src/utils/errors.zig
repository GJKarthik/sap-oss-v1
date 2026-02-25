//! Comprehensive Error Handling Framework
//!
//! Provides structured error types, error context, and recovery mechanisms
//! for production-grade error handling across the vLLM system.
//!
//! Features:
//! - Typed error categories
//! - Error context and stack traces
//! - Automatic retry logic
//! - Circuit breaker pattern
//! - Error metrics collection

const std = @import("std");
const log = @import("logging.zig");

// ==============================================
// Error Categories
// ==============================================

/// High-level error categories
pub const ErrorCategory = enum {
    /// Request validation errors (400)
    validation,
    
    /// Authentication/authorization errors (401/403)
    auth,
    
    /// Resource not found (404)
    not_found,
    
    /// Rate limiting (429)
    rate_limit,
    
    /// Internal server errors (500)
    internal,
    
    /// Service unavailable (503)
    unavailable,
    
    /// Timeout errors (504)
    timeout,
    
    /// Model-specific errors
    model,
    
    /// Memory/resource errors
    resource,
    
    /// Configuration errors
    config,
    
    /// Network/connectivity errors
    network,
    
    pub fn httpStatus(self: ErrorCategory) u16 {
        return switch (self) {
            .validation => 400,
            .auth => 401,
            .not_found => 404,
            .rate_limit => 429,
            .internal => 500,
            .unavailable => 503,
            .timeout => 504,
            .model => 500,
            .resource => 503,
            .config => 500,
            .network => 502,
        };
    }
    
    pub fn isRetryable(self: ErrorCategory) bool {
        return switch (self) {
            .rate_limit, .unavailable, .timeout, .network => true,
            else => false,
        };
    }
};

// ==============================================
// Specific Error Types
// ==============================================

/// Validation errors
pub const ValidationError = error{
    InvalidPrompt,
    PromptTooLong,
    InvalidMaxTokens,
    InvalidTemperature,
    InvalidTopP,
    InvalidTopK,
    InvalidStopSequence,
    InvalidModel,
    MissingRequiredField,
    InvalidJsonFormat,
};

/// Model errors
pub const ModelError = error{
    ModelNotFound,
    ModelLoadFailed,
    ModelNotReady,
    InferenceError,
    TokenizationError,
    OutOfMemory,
    ContextLengthExceeded,
    InvalidInputShape,
};

/// Resource errors
pub const ResourceError = error{
    OutOfGpuMemory,
    OutOfCpuMemory,
    KvCacheExhausted,
    BlockPoolExhausted,
    TooManyRequests,
    QueueFull,
};

/// Network errors
pub const NetworkError = error{
    ConnectionFailed,
    ConnectionReset,
    Timeout,
    DnsResolutionFailed,
    TlsHandshakeFailed,
};

/// Union of all error types
pub const VllmError = ValidationError || ModelError || ResourceError || NetworkError;

// ==============================================
// Error Context
// ==============================================

/// Detailed error context for debugging
pub const ErrorContext = struct {
    /// Error category
    category: ErrorCategory,
    
    /// Human-readable message
    message: []const u8,
    
    /// Original error (if wrapped)
    source_error: ?anyerror = null,
    
    /// Request ID for correlation
    request_id: ?[]const u8 = null,
    
    /// Timestamp when error occurred
    timestamp: i64,
    
    /// Additional metadata
    metadata: std.StringHashMap([]const u8),
    
    /// Stack trace (if available)
    stack_trace: ?[]const u8 = null,
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, category: ErrorCategory, message: []const u8) ErrorContext {
        return ErrorContext{
            .category = category,
            .message = message,
            .timestamp = std.time.timestamp(),
            .metadata = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ErrorContext) void {
        self.metadata.deinit();
    }
    
    pub fn withRequestId(self: *ErrorContext, request_id: []const u8) *ErrorContext {
        self.request_id = request_id;
        return self;
    }
    
    pub fn withSource(self: *ErrorContext, err: anyerror) *ErrorContext {
        self.source_error = err;
        return self;
    }
    
    pub fn addMetadata(self: *ErrorContext, key: []const u8, value: []const u8) !void {
        try self.metadata.put(key, value);
    }
    
    pub fn toJson(self: *ErrorContext) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        const writer = buffer.writer();
        
        try writer.print(
            \\{{"error":{{"category":"{s}","message":"{s}","status":{d}
        , .{
            @tagName(self.category),
            self.message,
            self.category.httpStatus(),
        });
        
        if (self.request_id) |rid| {
            try writer.print(",\"request_id\":\"{s}\"", .{rid});
        }
        
        try writer.print(",\"timestamp\":{d}}}}}", .{self.timestamp});
        
        return buffer.toOwnedSlice();
    }
};

// ==============================================
// Error Result Type
// ==============================================

/// Result type that carries error context
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: ErrorContext,
        
        const Self = @This();
        
        pub fn isOk(self: Self) bool {
            return self == .ok;
        }
        
        pub fn isErr(self: Self) bool {
            return self == .err;
        }
        
        pub fn unwrap(self: Self) T {
            return switch (self) {
                .ok => |v| v,
                .err => @panic("Called unwrap on error result"),
            };
        }
        
        pub fn unwrapOr(self: Self, default: T) T {
            return switch (self) {
                .ok => |v| v,
                .err => default,
            };
        }
        
        pub fn getError(self: Self) ?ErrorContext {
            return switch (self) {
                .ok => null,
                .err => |e| e,
            };
        }
    };
}

// ==============================================
// Circuit Breaker
// ==============================================

/// Circuit breaker states
pub const CircuitState = enum {
    closed,     // Normal operation
    open,       // Failing, reject requests
    half_open,  // Testing recovery
};

/// Circuit breaker for fault tolerance
pub const CircuitBreaker = struct {
    name: []const u8,
    state: CircuitState = .closed,
    
    /// Failure threshold before opening
    failure_threshold: u32 = 5,
    
    /// Success threshold to close from half-open
    success_threshold: u32 = 3,
    
    /// Time to wait before half-open (ms)
    reset_timeout_ms: u64 = 30000,
    
    /// Current counters
    failure_count: u32 = 0,
    success_count: u32 = 0,
    
    /// Last failure timestamp
    last_failure_time: i64 = 0,
    
    /// Mutex for thread safety
    mutex: std.Thread.Mutex = .{},
    
    pub fn init(name: []const u8) CircuitBreaker {
        return CircuitBreaker{ .name = name };
    }
    
    /// Check if request should be allowed
    pub fn allowRequest(self: *CircuitBreaker) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        switch (self.state) {
            .closed => return true,
            .open => {
                // Check if we should transition to half-open
                const now = std.time.milliTimestamp();
                if (now - self.last_failure_time >= @as(i64, @intCast(self.reset_timeout_ms))) {
                    self.state = .half_open;
                    self.success_count = 0;
                    log.info("Circuit breaker '{s}' transitioning to half-open", .{self.name});
                    return true;
                }
                return false;
            },
            .half_open => return true,
        }
    }
    
    /// Record a successful operation
    pub fn recordSuccess(self: *CircuitBreaker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        switch (self.state) {
            .closed => {
                self.failure_count = 0;
            },
            .half_open => {
                self.success_count += 1;
                if (self.success_count >= self.success_threshold) {
                    self.state = .closed;
                    self.failure_count = 0;
                    log.info("Circuit breaker '{s}' closed", .{self.name});
                }
            },
            .open => {},
        }
    }
    
    /// Record a failed operation
    pub fn recordFailure(self: *CircuitBreaker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.last_failure_time = std.time.milliTimestamp();
        
        switch (self.state) {
            .closed => {
                self.failure_count += 1;
                if (self.failure_count >= self.failure_threshold) {
                    self.state = .open;
                    log.warn("Circuit breaker '{s}' opened after {d} failures", .{
                        self.name, self.failure_count,
                    });
                }
            },
            .half_open => {
                self.state = .open;
                log.warn("Circuit breaker '{s}' reopened", .{self.name});
            },
            .open => {},
        }
    }
    
    /// Get current state
    pub fn getState(self: *CircuitBreaker) CircuitState {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state;
    }
};

// ==============================================
// Retry Logic
// ==============================================

/// Retry configuration
pub const RetryConfig = struct {
    /// Maximum number of retries
    max_retries: u32 = 3,
    
    /// Initial delay between retries (ms)
    initial_delay_ms: u64 = 100,
    
    /// Maximum delay between retries (ms)
    max_delay_ms: u64 = 10000,
    
    /// Exponential backoff multiplier
    backoff_multiplier: f32 = 2.0,
    
    /// Add jitter to delays
    jitter: bool = true,
};

/// Retry helper
pub fn retry(
    comptime T: type,
    config: RetryConfig,
    operation: *const fn () anyerror!T,
) anyerror!T {
    var attempt: u32 = 0;
    var delay_ms: u64 = config.initial_delay_ms;
    
    while (true) {
        const result = operation() catch |err| {
            attempt += 1;
            
            if (attempt > config.max_retries) {
                log.err("Retry exhausted after {d} attempts", .{attempt});
                return err;
            }
            
            log.warn("Attempt {d} failed, retrying in {d}ms: {s}", .{
                attempt, delay_ms, @errorName(err),
            });
            
            // Sleep with jitter
            var actual_delay = delay_ms;
            if (config.jitter) {
                const jitter_range = delay_ms / 4;
                actual_delay = delay_ms - jitter_range / 2 +
                    @as(u64, @intCast(std.crypto.random.int(u32) % @as(u32, @intCast(jitter_range))));
            }
            
            std.time.sleep(actual_delay * std.time.ns_per_ms);
            
            // Exponential backoff
            delay_ms = @min(
                @as(u64, @intFromFloat(@as(f32, @floatFromInt(delay_ms)) * config.backoff_multiplier)),
                config.max_delay_ms,
            );
            
            continue;
        };
        
        return result;
    }
}

// ==============================================
// Error Metrics
// ==============================================

/// Error metrics collector
pub const ErrorMetrics = struct {
    allocator: std.mem.Allocator,
    
    /// Error counts by category
    error_counts: std.EnumArray(ErrorCategory, u64),
    
    /// Recent errors (ring buffer)
    recent_errors: std.ArrayList(ErrorContext),
    max_recent: usize = 100,
    
    /// Mutex for thread safety
    mutex: std.Thread.Mutex = .{},
    
    pub fn init(allocator: std.mem.Allocator) ErrorMetrics {
        return ErrorMetrics{
            .allocator = allocator,
            .error_counts = std.EnumArray(ErrorCategory, u64).initFill(0),
            .recent_errors = std.ArrayList(ErrorContext).init(allocator),
        };
    }
    
    pub fn deinit(self: *ErrorMetrics) void {
        for (self.recent_errors.items) |*err| {
            err.deinit();
        }
        self.recent_errors.deinit();
    }
    
    pub fn record(self: *ErrorMetrics, ctx: ErrorContext) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.error_counts.set(ctx.category, self.error_counts.get(ctx.category) + 1);
        
        if (self.recent_errors.items.len >= self.max_recent) {
            var old = self.recent_errors.orderedRemove(0);
            old.deinit();
        }
        try self.recent_errors.append(ctx);
    }
    
    pub fn getCount(self: *ErrorMetrics, category: ErrorCategory) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.error_counts.get(category);
    }
    
    pub fn getTotalCount(self: *ErrorMetrics) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var total: u64 = 0;
        for (std.enums.values(ErrorCategory)) |cat| {
            total += self.error_counts.get(cat);
        }
        return total;
    }
};

// ==============================================
// Error Handlers
// ==============================================

/// Create validation error context
pub fn validationError(
    allocator: std.mem.Allocator,
    message: []const u8,
) ErrorContext {
    return ErrorContext.init(allocator, .validation, message);
}

/// Create model error context
pub fn modelError(
    allocator: std.mem.Allocator,
    message: []const u8,
) ErrorContext {
    return ErrorContext.init(allocator, .model, message);
}

/// Create resource error context
pub fn resourceError(
    allocator: std.mem.Allocator,
    message: []const u8,
) ErrorContext {
    return ErrorContext.init(allocator, .resource, message);
}

/// Create timeout error context
pub fn timeoutError(
    allocator: std.mem.Allocator,
    message: []const u8,
) ErrorContext {
    return ErrorContext.init(allocator, .timeout, message);
}

// ==============================================
// Tests
// ==============================================

test "CircuitBreaker state transitions" {
    var breaker = CircuitBreaker.init("test");
    
    // Initial state is closed
    try std.testing.expectEqual(CircuitState.closed, breaker.getState());
    try std.testing.expect(breaker.allowRequest());
    
    // Record failures to open
    for (0..5) |_| {
        breaker.recordFailure();
    }
    try std.testing.expectEqual(CircuitState.open, breaker.getState());
    try std.testing.expect(!breaker.allowRequest());
}

test "ErrorContext JSON serialization" {
    const allocator = std.testing.allocator;
    var ctx = ErrorContext.init(allocator, .validation, "Invalid prompt");
    defer ctx.deinit();
    
    const json = try ctx.toJson();
    defer allocator.free(json);
    
    try std.testing.expect(std.mem.indexOf(u8, json, "validation") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "400") != null);
}