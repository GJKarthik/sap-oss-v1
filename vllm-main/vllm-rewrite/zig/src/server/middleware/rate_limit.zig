//! Rate Limiting Middleware
//!
//! Implements rate limiting to protect the service from abuse.
//! Supports multiple rate limiting strategies.
//!
//! Features:
//! - Token bucket algorithm
//! - Sliding window algorithm
//! - Per-user/API key limits
//! - Global limits
//! - Burst handling

const std = @import("std");
const log = @import("../../utils/logging.zig");

// ==============================================
// Rate Limit Configuration
// ==============================================

pub const RateLimitConfig = struct {
    /// Requests per minute (global)
    requests_per_minute: u32 = 60,
    
    /// Requests per minute per user
    user_requests_per_minute: u32 = 30,
    
    /// Tokens per minute (global)
    tokens_per_minute: u64 = 100_000,
    
    /// Tokens per minute per user
    user_tokens_per_minute: u64 = 50_000,
    
    /// Maximum burst size
    burst_size: u32 = 10,
    
    /// Window size in seconds (for sliding window)
    window_size_seconds: u64 = 60,
    
    /// Enable rate limiting
    enabled: bool = true,
};

// ==============================================
// Rate Limit Result
// ==============================================

pub const RateLimitResult = struct {
    allowed: bool,
    remaining: u32 = 0,
    reset_at: i64 = 0,
    retry_after_ms: ?u64 = null,
    
    pub fn allow(remaining: u32, reset_at: i64) RateLimitResult {
        return RateLimitResult{
            .allowed = true,
            .remaining = remaining,
            .reset_at = reset_at,
        };
    }
    
    pub fn deny(retry_after_ms: u64, reset_at: i64) RateLimitResult {
        return RateLimitResult{
            .allowed = false,
            .retry_after_ms = retry_after_ms,
            .reset_at = reset_at,
        };
    }
};

// ==============================================
// Token Bucket
// ==============================================

pub const TokenBucket = struct {
    /// Maximum tokens in bucket
    capacity: u32,
    
    /// Current tokens available
    tokens: f64,
    
    /// Tokens added per second
    refill_rate: f64,
    
    /// Last refill timestamp
    last_refill: i64,
    
    pub fn init(capacity: u32, refill_rate: f64) TokenBucket {
        return TokenBucket{
            .capacity = capacity,
            .tokens = @as(f64, @floatFromInt(capacity)),
            .refill_rate = refill_rate,
            .last_refill = std.time.milliTimestamp(),
        };
    }
    
    pub fn tryConsume(self: *TokenBucket, count: u32) bool {
        self.refill();
        
        const needed = @as(f64, @floatFromInt(count));
        if (self.tokens >= needed) {
            self.tokens -= needed;
            return true;
        }
        return false;
    }
    
    pub fn getAvailable(self: *TokenBucket) u32 {
        self.refill();
        return @as(u32, @intFromFloat(self.tokens));
    }
    
    fn refill(self: *TokenBucket) void {
        const now = std.time.milliTimestamp();
        const elapsed_ms = @as(f64, @floatFromInt(now - self.last_refill));
        const elapsed_seconds = elapsed_ms / 1000.0;
        
        const new_tokens = elapsed_seconds * self.refill_rate;
        self.tokens = @min(self.tokens + new_tokens, @as(f64, @floatFromInt(self.capacity)));
        self.last_refill = now;
    }
    
    pub fn timeUntilAvailable(self: *TokenBucket, count: u32) u64 {
        self.refill();
        
        const needed = @as(f64, @floatFromInt(count));
        if (self.tokens >= needed) {
            return 0;
        }
        
        const deficit = needed - self.tokens;
        const seconds_needed = deficit / self.refill_rate;
        return @as(u64, @intFromFloat(seconds_needed * 1000));
    }
};

// ==============================================
// Sliding Window Counter
// ==============================================

pub const SlidingWindowCounter = struct {
    allocator: std.mem.Allocator,
    
    /// Window size in milliseconds
    window_ms: u64,
    
    /// Number of sub-windows
    num_buckets: usize,
    
    /// Bucket size in milliseconds
    bucket_ms: u64,
    
    /// Counts per bucket
    buckets: []u64,
    
    /// Current bucket index
    current_bucket: usize,
    
    /// Last bucket update time
    last_update: i64,
    
    pub fn init(allocator: std.mem.Allocator, window_seconds: u64, num_buckets: usize) !SlidingWindowCounter {
        const window_ms = window_seconds * 1000;
        const bucket_ms = window_ms / num_buckets;
        
        const buckets = try allocator.alloc(u64, num_buckets);
        @memset(buckets, 0);
        
        return SlidingWindowCounter{
            .allocator = allocator,
            .window_ms = window_ms,
            .num_buckets = num_buckets,
            .bucket_ms = bucket_ms,
            .buckets = buckets,
            .current_bucket = 0,
            .last_update = std.time.milliTimestamp(),
        };
    }
    
    pub fn deinit(self: *SlidingWindowCounter) void {
        self.allocator.free(self.buckets);
    }
    
    pub fn increment(self: *SlidingWindowCounter, count: u64) void {
        self.advanceBuckets();
        self.buckets[self.current_bucket] += count;
    }
    
    pub fn getCount(self: *SlidingWindowCounter) u64 {
        self.advanceBuckets();
        
        var total: u64 = 0;
        for (self.buckets) |count| {
            total += count;
        }
        return total;
    }
    
    fn advanceBuckets(self: *SlidingWindowCounter) void {
        const now = std.time.milliTimestamp();
        const elapsed = @as(u64, @intCast(now - self.last_update));
        
        const buckets_to_advance = elapsed / self.bucket_ms;
        
        if (buckets_to_advance >= self.num_buckets) {
            // Clear all buckets
            @memset(self.buckets, 0);
            self.current_bucket = 0;
        } else if (buckets_to_advance > 0) {
            // Clear old buckets and advance
            for (0..buckets_to_advance) |_| {
                self.current_bucket = (self.current_bucket + 1) % self.num_buckets;
                self.buckets[self.current_bucket] = 0;
            }
        }
        
        self.last_update = now;
    }
};

// ==============================================
// Rate Limiter
// ==============================================

pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    config: RateLimitConfig,
    
    /// Global request bucket
    global_bucket: TokenBucket,
    
    /// Global token bucket
    global_token_bucket: TokenBucket,
    
    /// Per-user buckets
    user_buckets: std.StringHashMap(TokenBucket),
    
    /// Per-user token buckets
    user_token_buckets: std.StringHashMap(TokenBucket),
    
    /// Mutex for thread safety
    mutex: std.Thread.Mutex = .{},
    
    pub fn init(allocator: std.mem.Allocator, config: RateLimitConfig) RateLimiter {
        const requests_per_second = @as(f64, @floatFromInt(config.requests_per_minute)) / 60.0;
        const tokens_per_second = @as(f64, @floatFromInt(config.tokens_per_minute)) / 60.0;
        
        return RateLimiter{
            .allocator = allocator,
            .config = config,
            .global_bucket = TokenBucket.init(
                config.requests_per_minute,
                requests_per_second,
            ),
            .global_token_bucket = TokenBucket.init(
                @as(u32, @intCast(@min(config.tokens_per_minute, std.math.maxInt(u32)))),
                tokens_per_second,
            ),
            .user_buckets = std.StringHashMap(TokenBucket).init(allocator),
            .user_token_buckets = std.StringHashMap(TokenBucket).init(allocator),
        };
    }
    
    pub fn deinit(self: *RateLimiter) void {
        self.user_buckets.deinit();
        self.user_token_buckets.deinit();
    }
    
    /// Check if request is allowed
    pub fn checkRequest(
        self: *RateLimiter,
        user_id: ?[]const u8,
    ) RateLimitResult {
        if (!self.config.enabled) {
            return RateLimitResult.allow(
                std.math.maxInt(u32),
                std.time.timestamp() + 60,
            );
        }
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check global limit
        if (!self.global_bucket.tryConsume(1)) {
            const retry_after = self.global_bucket.timeUntilAvailable(1);
            return RateLimitResult.deny(
                retry_after,
                std.time.timestamp() + @as(i64, @intCast(retry_after / 1000)),
            );
        }
        
        // Check per-user limit
        if (user_id) |uid| {
            if (self.user_buckets.get(uid)) |*bucket| {
                if (!bucket.tryConsume(1)) {
                    const retry_after = bucket.timeUntilAvailable(1);
                    return RateLimitResult.deny(
                        retry_after,
                        std.time.timestamp() + @as(i64, @intCast(retry_after / 1000)),
                    );
                }
            } else {
                // Create new user bucket
                const user_rps = @as(f64, @floatFromInt(self.config.user_requests_per_minute)) / 60.0;
                var bucket = TokenBucket.init(self.config.user_requests_per_minute, user_rps);
                _ = bucket.tryConsume(1);
                self.user_buckets.put(uid, bucket) catch {};
            }
        }
        
        const remaining = self.global_bucket.getAvailable();
        return RateLimitResult.allow(
            remaining,
            std.time.timestamp() + 60,
        );
    }
    
    /// Check if token usage is allowed
    pub fn checkTokens(
        self: *RateLimiter,
        user_id: ?[]const u8,
        token_count: u32,
    ) RateLimitResult {
        if (!self.config.enabled) {
            return RateLimitResult.allow(
                std.math.maxInt(u32),
                std.time.timestamp() + 60,
            );
        }
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check global token limit
        if (!self.global_token_bucket.tryConsume(token_count)) {
            const retry_after = self.global_token_bucket.timeUntilAvailable(token_count);
            return RateLimitResult.deny(
                retry_after,
                std.time.timestamp() + @as(i64, @intCast(retry_after / 1000)),
            );
        }
        
        // Check per-user token limit
        if (user_id) |uid| {
            if (self.user_token_buckets.get(uid)) |*bucket| {
                if (!bucket.tryConsume(token_count)) {
                    const retry_after = bucket.timeUntilAvailable(token_count);
                    return RateLimitResult.deny(
                        retry_after,
                        std.time.timestamp() + @as(i64, @intCast(retry_after / 1000)),
                    );
                }
            } else {
                // Create new user token bucket
                const user_tps = @as(f64, @floatFromInt(self.config.user_tokens_per_minute)) / 60.0;
                const capacity = @as(u32, @intCast(@min(self.config.user_tokens_per_minute, std.math.maxInt(u32))));
                var bucket = TokenBucket.init(capacity, user_tps);
                _ = bucket.tryConsume(token_count);
                self.user_token_buckets.put(uid, bucket) catch {};
            }
        }
        
        const remaining = self.global_token_bucket.getAvailable();
        return RateLimitResult.allow(
            remaining,
            std.time.timestamp() + 60,
        );
    }
};

// ==============================================
// Rate Limit Middleware
// ==============================================

pub const RateLimitMiddleware = struct {
    limiter: RateLimiter,
    
    pub fn init(allocator: std.mem.Allocator, config: RateLimitConfig) RateLimitMiddleware {
        return RateLimitMiddleware{
            .limiter = RateLimiter.init(allocator, config),
        };
    }
    
    pub fn deinit(self: *RateLimitMiddleware) void {
        self.limiter.deinit();
    }
    
    /// Check rate limit for request
    pub fn check(
        self: *RateLimitMiddleware,
        user_id: ?[]const u8,
        estimated_tokens: ?u32,
    ) RateLimitResult {
        // Check request rate
        const request_result = self.limiter.checkRequest(user_id);
        if (!request_result.allowed) {
            return request_result;
        }
        
        // Check token rate if applicable
        if (estimated_tokens) |tokens| {
            return self.limiter.checkTokens(user_id, tokens);
        }
        
        return request_result;
    }
    
    /// Get headers for rate limit response
    pub fn getHeaders(self: *RateLimitMiddleware, user_id: ?[]const u8) RateLimitHeaders {
        const result = self.limiter.checkRequest(user_id);
        return RateLimitHeaders{
            .limit = self.limiter.config.requests_per_minute,
            .remaining = result.remaining,
            .reset = result.reset_at,
        };
    }
};

pub const RateLimitHeaders = struct {
    limit: u32,
    remaining: u32,
    reset: i64,
};

// ==============================================
// Tests
// ==============================================

test "TokenBucket basic operations" {
    var bucket = TokenBucket.init(10, 1.0);  // 10 capacity, 1/s refill
    
    // Should allow initial consumption
    try std.testing.expect(bucket.tryConsume(5));
    try std.testing.expectEqual(@as(u32, 5), bucket.getAvailable());
    
    // Should allow more
    try std.testing.expect(bucket.tryConsume(5));
    try std.testing.expectEqual(@as(u32, 0), bucket.getAvailable());
    
    // Should deny when empty
    try std.testing.expect(!bucket.tryConsume(1));
}

test "RateLimiter respects limits" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, .{ .requests_per_minute = 5 });
    defer limiter.deinit();
    
    // First 5 should be allowed
    for (0..5) |_| {
        try std.testing.expect(limiter.checkRequest(null).allowed);
    }
    
    // 6th should be denied
    try std.testing.expect(!limiter.checkRequest(null).allowed);
}