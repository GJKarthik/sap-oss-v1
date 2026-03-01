//! Rate Limiting Middleware
//!
//! Implements token bucket rate limiting to protect endpoints from abuse.
//! Supports per-IP, per-user, and global rate limits.

const std = @import("std");
const time = std.time;
const Allocator = std.mem.Allocator;

/// Rate limit configuration
pub const RateLimitConfig = struct {
    /// Requests allowed per window
    requests_per_window: u32 = 100,
    /// Window size in seconds
    window_seconds: u32 = 60,
    /// Burst allowance (extra requests before throttling)
    burst_size: u32 = 20,
    /// Enable per-IP limiting
    per_ip: bool = true,
    /// Enable per-user limiting (from JWT)
    per_user: bool = true,
    /// Global rate limit (0 = disabled)
    global_limit: u32 = 10000,
};

/// Token bucket for rate limiting
const TokenBucket = struct {
    tokens: f64,
    last_update: i64,
    max_tokens: f64,
    refill_rate: f64,

    fn init(max_tokens: f64, refill_rate: f64) TokenBucket {
        return .{
            .tokens = max_tokens,
            .last_update = time.milliTimestamp(),
            .max_tokens = max_tokens,
            .refill_rate = refill_rate,
        };
    }

    fn tryConsume(self: *TokenBucket, count: f64) bool {
        self.refill();
        if (self.tokens >= count) {
            self.tokens -= count;
            return true;
        }
        return false;
    }

    fn refill(self: *TokenBucket) void {
        const now = time.milliTimestamp();
        const elapsed_ms = @as(f64, @floatFromInt(now - self.last_update));
        const tokens_to_add = (elapsed_ms / 1000.0) * self.refill_rate;
        self.tokens = @min(self.max_tokens, self.tokens + tokens_to_add);
        self.last_update = now;
    }

    fn tokensRemaining(self: *TokenBucket) u32 {
        self.refill();
        return @intFromFloat(self.tokens);
    }
};

/// Rate limiter result
pub const RateLimitResult = struct {
    allowed: bool,
    remaining: u32,
    reset_seconds: u32,
    retry_after: ?u32 = null,
};

/// Rate limiter
pub const RateLimiter = struct {
    allocator: Allocator,
    config: RateLimitConfig,
    buckets: std.StringHashMap(TokenBucket),
    global_bucket: TokenBucket,
    mutex: std.Thread.Mutex,
    cleanup_interval: i64,
    last_cleanup: i64,

    const Self = @This();

    pub fn init(allocator: Allocator, config: RateLimitConfig) Self {
        const refill_rate = @as(f64, @floatFromInt(config.requests_per_window)) /
            @as(f64, @floatFromInt(config.window_seconds));

        return Self{
            .allocator = allocator,
            .config = config,
            .buckets = std.StringHashMap(TokenBucket).init(allocator),
            .global_bucket = TokenBucket.init(
                @as(f64, @floatFromInt(config.global_limit)),
                @as(f64, @floatFromInt(config.global_limit)) / 60.0,
            ),
            .mutex = .{},
            .cleanup_interval = 300000, // 5 minutes in ms
            .last_cleanup = time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.buckets.deinit();
    }

    /// Check if request should be allowed
    pub fn checkLimit(self: *Self, key: []const u8) RateLimitResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Cleanup old buckets periodically
        self.maybeCleanup();

        // Check global limit first
        if (self.config.global_limit > 0) {
            if (!self.global_bucket.tryConsume(1)) {
                return RateLimitResult{
                    .allowed = false,
                    .remaining = 0,
                    .reset_seconds = self.config.window_seconds,
                    .retry_after = self.config.window_seconds,
                };
            }
        }

        // Get or create bucket for this key
        const refill_rate = @as(f64, @floatFromInt(self.config.requests_per_window)) /
            @as(f64, @floatFromInt(self.config.window_seconds));
        const max_tokens = @as(f64, @floatFromInt(self.config.requests_per_window + self.config.burst_size));

        const bucket = self.buckets.getPtr(key) orelse blk: {
            const new_bucket = TokenBucket.init(max_tokens, refill_rate);
            self.buckets.put(key, new_bucket) catch {
                return RateLimitResult{
                    .allowed = true,
                    .remaining = self.config.requests_per_window,
                    .reset_seconds = self.config.window_seconds,
                };
            };
            break :blk self.buckets.getPtr(key).?;
        };

        if (bucket.tryConsume(1)) {
            return RateLimitResult{
                .allowed = true,
                .remaining = bucket.tokensRemaining(),
                .reset_seconds = self.config.window_seconds,
            };
        } else {
            return RateLimitResult{
                .allowed = false,
                .remaining = 0,
                .reset_seconds = self.config.window_seconds,
                .retry_after = @intFromFloat(@ceil(1.0 / refill_rate)),
            };
        }
    }

    /// Check limit by IP address
    pub fn checkIpLimit(self: *Self, ip: []const u8) RateLimitResult {
        if (!self.config.per_ip) {
            return RateLimitResult{ .allowed = true, .remaining = 999, .reset_seconds = 0 };
        }

        var key_buf: [64]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "ip:{s}", .{ip}) catch ip;
        return self.checkLimit(key);
    }

    /// Check limit by user ID
    pub fn checkUserLimit(self: *Self, user_id: []const u8) RateLimitResult {
        if (!self.config.per_user) {
            return RateLimitResult{ .allowed = true, .remaining = 999, .reset_seconds = 0 };
        }

        var key_buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "user:{s}", .{user_id}) catch user_id;
        return self.checkLimit(key);
    }

    fn maybeCleanup(self: *Self) void {
        const now = time.milliTimestamp();
        if (now - self.last_cleanup > self.cleanup_interval) {
            // Remove buckets that haven't been used recently
            var it = self.buckets.iterator();
            while (it.next()) |entry| {
                const bucket = entry.value_ptr;
                if (now - bucket.last_update > self.cleanup_interval) {
                    _ = self.buckets.remove(entry.key_ptr.*);
                }
            }
            self.last_cleanup = now;
        }
    }
};

/// Rate limit response headers
pub const RateLimitHeaders = struct {
    x_ratelimit_limit: u32,
    x_ratelimit_remaining: u32,
    x_ratelimit_reset: u32,
    retry_after: ?u32,

    pub fn fromResult(result: RateLimitResult, config: RateLimitConfig) RateLimitHeaders {
        return .{
            .x_ratelimit_limit = config.requests_per_window,
            .x_ratelimit_remaining = result.remaining,
            .x_ratelimit_reset = result.reset_seconds,
            .retry_after = result.retry_after,
        };
    }

    pub fn toHeaderString(self: RateLimitHeaders, allocator: Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer();

        try writer.print("X-RateLimit-Limit: {d}\r\n", .{self.x_ratelimit_limit});
        try writer.print("X-RateLimit-Remaining: {d}\r\n", .{self.x_ratelimit_remaining});
        try writer.print("X-RateLimit-Reset: {d}\r\n", .{self.x_ratelimit_reset});

        if (self.retry_after) |retry| {
            try writer.print("Retry-After: {d}\r\n", .{retry});
        }

        return buf.toOwnedSlice();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "rate limiter basic" {
    var limiter = RateLimiter.init(std.testing.allocator, .{
        .requests_per_window = 5,
        .window_seconds = 60,
        .burst_size = 0,
        .global_limit = 0,
    });
    defer limiter.deinit();

    // First 5 requests should pass
    for (0..5) |_| {
        const result = limiter.checkLimit("test-key");
        try std.testing.expect(result.allowed);
    }

    // 6th request should be blocked
    const blocked = limiter.checkLimit("test-key");
    try std.testing.expect(!blocked.allowed);
    try std.testing.expect(blocked.retry_after != null);
}

test "rate limiter per-ip" {
    var limiter = RateLimiter.init(std.testing.allocator, .{
        .requests_per_window = 3,
        .window_seconds = 60,
        .per_ip = true,
    });
    defer limiter.deinit();

    // Different IPs should have separate limits
    _ = limiter.checkIpLimit("192.168.1.1");
    _ = limiter.checkIpLimit("192.168.1.1");
    _ = limiter.checkIpLimit("192.168.1.1");

    const blocked = limiter.checkIpLimit("192.168.1.1");
    try std.testing.expect(!blocked.allowed);

    // Different IP should still work
    const other_ip = limiter.checkIpLimit("192.168.1.2");
    try std.testing.expect(other_ip.allowed);
}