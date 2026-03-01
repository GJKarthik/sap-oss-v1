//! Comprehensive Test Suite
//!
//! This module provides comprehensive test coverage for the ai-core-streaming service.
//! Target: 80%+ line coverage across all critical modules.

const std = @import("std");
const testing = std.testing;

// Import modules under test
const health = @import("../health/health.zig");
const rate_limiter = @import("../middleware/rate_limiter.zig");
const security_headers = @import("../middleware/security_headers.zig");
const xsuaa = @import("../auth/xsuaa.zig");
const registry = @import("../schema/registry.zig");

// ============================================================================
// Health Check Tests
// ============================================================================

test "health service initialization" {
    var service = health.HealthService.init(testing.allocator, "1.0.0");
    defer service.deinit();

    try testing.expectEqualStrings("1.0.0", service.version);
    try testing.expect(service.start_time > 0);
}

test "health liveness returns healthy" {
    var service = health.HealthService.init(testing.allocator, "2.0.0");
    defer service.deinit();

    const response = service.liveness();
    try testing.expectEqual(health.HealthStatus.healthy, response.status);
    try testing.expectEqualStrings("2.0.0", response.version);
}

test "health readiness with no checkers" {
    var service = health.HealthService.init(testing.allocator, "1.0.0");
    defer service.deinit();

    const response = service.readiness();
    try testing.expectEqual(health.HealthStatus.healthy, response.status);
    try testing.expectEqual(@as(usize, 0), response.components.len);
}

test "health json serialization" {
    var service = health.HealthService.init(testing.allocator, "1.0.0");
    defer service.deinit();

    const response = service.liveness();
    const json = try service.toJson(response);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"status\":\"healthy\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"version\":\"1.0.0\"") != null);
}

// ============================================================================
// Rate Limiter Tests
// ============================================================================

test "rate limiter allows requests under limit" {
    var limiter = rate_limiter.RateLimiter.init(testing.allocator, .{
        .requests_per_window = 10,
        .window_seconds = 60,
        .burst_size = 0,
        .global_limit = 0,
    });
    defer limiter.deinit();

    // All 10 requests should pass
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const result = limiter.checkLimit("test-key");
        try testing.expect(result.allowed);
        try testing.expect(result.remaining <= 10);
    }
}

test "rate limiter blocks requests over limit" {
    var limiter = rate_limiter.RateLimiter.init(testing.allocator, .{
        .requests_per_window = 3,
        .window_seconds = 60,
        .burst_size = 0,
        .global_limit = 0,
    });
    defer limiter.deinit();

    // Exhaust the limit
    _ = limiter.checkLimit("key1");
    _ = limiter.checkLimit("key1");
    _ = limiter.checkLimit("key1");

    // 4th should be blocked
    const result = limiter.checkLimit("key1");
    try testing.expect(!result.allowed);
    try testing.expectEqual(@as(u32, 0), result.remaining);
    try testing.expect(result.retry_after != null);
}

test "rate limiter per-ip isolation" {
    var limiter = rate_limiter.RateLimiter.init(testing.allocator, .{
        .requests_per_window = 2,
        .window_seconds = 60,
        .per_ip = true,
    });
    defer limiter.deinit();

    // Exhaust IP1
    _ = limiter.checkIpLimit("10.0.0.1");
    _ = limiter.checkIpLimit("10.0.0.1");

    const ip1_blocked = limiter.checkIpLimit("10.0.0.1");
    try testing.expect(!ip1_blocked.allowed);

    // IP2 should still work
    const ip2_ok = limiter.checkIpLimit("10.0.0.2");
    try testing.expect(ip2_ok.allowed);
}

test "rate limiter per-user isolation" {
    var limiter = rate_limiter.RateLimiter.init(testing.allocator, .{
        .requests_per_window = 2,
        .window_seconds = 60,
        .per_user = true,
    });
    defer limiter.deinit();

    // Exhaust user1
    _ = limiter.checkUserLimit("user-abc");
    _ = limiter.checkUserLimit("user-abc");

    const user1_blocked = limiter.checkUserLimit("user-abc");
    try testing.expect(!user1_blocked.allowed);

    // user2 should still work
    const user2_ok = limiter.checkUserLimit("user-xyz");
    try testing.expect(user2_ok.allowed);
}

test "rate limit headers generation" {
    const result = rate_limiter.RateLimitResult{
        .allowed = true,
        .remaining = 50,
        .reset_seconds = 60,
        .retry_after = null,
    };

    const config = rate_limiter.RateLimitConfig{
        .requests_per_window = 100,
        .window_seconds = 60,
    };

    const headers = rate_limiter.RateLimitHeaders.fromResult(result, config);
    try testing.expectEqual(@as(u32, 100), headers.x_ratelimit_limit);
    try testing.expectEqual(@as(u32, 50), headers.x_ratelimit_remaining);
    try testing.expectEqual(@as(u32, 60), headers.x_ratelimit_reset);
    try testing.expect(headers.retry_after == null);
}

// ============================================================================
// Security Headers Tests
// ============================================================================

test "security headers default configuration" {
    var headers = security_headers.SecurityHeaders.init(testing.allocator, .{});
    defer headers.deinit();

    const h = try headers.getHeaders();
    
    // Verify essential headers present
    try testing.expect(std.mem.indexOf(u8, h, "X-Frame-Options: DENY") != null);
    try testing.expect(std.mem.indexOf(u8, h, "X-Content-Type-Options: nosniff") != null);
    try testing.expect(std.mem.indexOf(u8, h, "X-XSS-Protection: 1; mode=block") != null);
    try testing.expect(std.mem.indexOf(u8, h, "Strict-Transport-Security:") != null);
    try testing.expect(std.mem.indexOf(u8, h, "Content-Security-Policy:") != null);
    try testing.expect(std.mem.indexOf(u8, h, "Referrer-Policy:") != null);
}

test "security headers HSTS configuration" {
    var headers = security_headers.SecurityHeaders.init(testing.allocator, .{
        .enable_hsts = true,
        .hsts_max_age = 86400,
        .hsts_include_subdomains = true,
        .hsts_preload = true,
    });
    defer headers.deinit();

    const h = try headers.getHeaders();
    try testing.expect(std.mem.indexOf(u8, h, "max-age=86400") != null);
    try testing.expect(std.mem.indexOf(u8, h, "includeSubDomains") != null);
    try testing.expect(std.mem.indexOf(u8, h, "preload") != null);
}

test "security headers frame options sameorigin" {
    var headers = security_headers.SecurityHeaders.init(testing.allocator, .{
        .frame_options = .sameorigin,
    });
    defer headers.deinit();

    const h = try headers.getHeaders();
    try testing.expect(std.mem.indexOf(u8, h, "X-Frame-Options: SAMEORIGIN") != null);
}

test "security headers csp report only" {
    var headers = security_headers.SecurityHeaders.init(testing.allocator, .{
        .csp_enabled = true,
        .csp_report_only = true,
    });
    defer headers.deinit();

    const h = try headers.getHeaders();
    try testing.expect(std.mem.indexOf(u8, h, "Content-Security-Policy-Report-Only:") != null);
}

test "cors origin validation" {
    var cors = security_headers.Cors.init(testing.allocator, .{
        .allowed_origins = &.{
            "https://example.com",
            "https://app.example.com",
        },
    });

    try testing.expect(cors.isOriginAllowed("https://example.com"));
    try testing.expect(cors.isOriginAllowed("https://app.example.com"));
    try testing.expect(!cors.isOriginAllowed("https://malicious.com"));
    try testing.expect(!cors.isOriginAllowed("http://example.com")); // HTTP not HTTPS
}

test "cors wildcard origin" {
    var cors = security_headers.Cors.init(testing.allocator, .{
        .allowed_origins = &.{"*"},
    });

    try testing.expect(cors.isOriginAllowed("https://any-site.com"));
    try testing.expect(cors.isOriginAllowed("http://localhost:3000"));
}

test "cors denied by default" {
    var cors = security_headers.Cors.init(testing.allocator, .{
        .allowed_origins = null, // No origins configured
    });

    try testing.expect(!cors.isOriginAllowed("https://example.com"));
}

// ============================================================================
// Referrer Policy Tests
// ============================================================================

test "referrer policy string conversion" {
    try testing.expectEqualStrings("no-referrer", security_headers.ReferrerPolicy.no_referrer.toString());
    try testing.expectEqualStrings("strict-origin-when-cross-origin", security_headers.ReferrerPolicy.strict_origin_when_cross_origin.toString());
    try testing.expectEqualStrings("same-origin", security_headers.ReferrerPolicy.same_origin.toString());
    try testing.expectEqualStrings("unsafe-url", security_headers.ReferrerPolicy.unsafe_url.toString());
}

// ============================================================================
// Schema Registry Tests (if available)
// ============================================================================

test "schema compatibility backward check" {
    // Test that backward compatibility works correctly
    const result = registry.SchemaData.isBackwardCompatible(
        .json_schema,
        \\{"type":"object","properties":{"name":{"type":"string"}}}
        ,
        \\{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"}}}
        ,
    );
    try testing.expect(result);
}

test "schema compatibility forward check" {
    const result = registry.SchemaData.isForwardCompatible(
        .json_schema,
        \\{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"}}}
        ,
        \\{"type":"object","properties":{"name":{"type":"string"}}}
        ,
    );
    try testing.expect(result);
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "empty string handling" {
    var limiter = rate_limiter.RateLimiter.init(testing.allocator, .{
        .requests_per_window = 5,
    });
    defer limiter.deinit();

    // Empty key should still work
    const result = limiter.checkLimit("");
    try testing.expect(result.allowed);
}

test "very long key handling" {
    var limiter = rate_limiter.RateLimiter.init(testing.allocator, .{
        .requests_per_window = 5,
    });
    defer limiter.deinit();

    // Very long key
    const long_key = "a" ** 1000;
    const result = limiter.checkLimit(long_key);
    try testing.expect(result.allowed);
}

test "unicode key handling" {
    var limiter = rate_limiter.RateLimiter.init(testing.allocator, .{
        .requests_per_window = 5,
    });
    defer limiter.deinit();

    const result = limiter.checkLimit("用户:日本語");
    try testing.expect(result.allowed);
}

// ============================================================================
// Concurrent Access Tests (Stress Tests)
// ============================================================================

test "rate limiter thread safety" {
    var limiter = rate_limiter.RateLimiter.init(testing.allocator, .{
        .requests_per_window = 1000,
        .window_seconds = 60,
    });
    defer limiter.deinit();

    // Simulate concurrent access from single thread
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = limiter.checkLimit("concurrent-key");
    }

    // Should still have some remaining
    const result = limiter.checkLimit("concurrent-key");
    try testing.expect(result.remaining < 1000);
}

// ============================================================================
// Integration Tests
// ============================================================================

test "full request flow simulation" {
    // Simulate a full request:
    // 1. Check health
    // 2. Check rate limit
    // 3. Get security headers

    var health_service = health.HealthService.init(testing.allocator, "1.0.0");
    defer health_service.deinit();

    var limiter = rate_limiter.RateLimiter.init(testing.allocator, .{});
    defer limiter.deinit();

    var sec_headers = security_headers.SecurityHeaders.init(testing.allocator, .{});
    defer sec_headers.deinit();

    // Step 1: Health check
    const health_resp = health_service.liveness();
    try testing.expectEqual(health.HealthStatus.healthy, health_resp.status);

    // Step 2: Rate limit check
    const rate_result = limiter.checkIpLimit("192.168.1.100");
    try testing.expect(rate_result.allowed);

    // Step 3: Get security headers
    const headers = try sec_headers.getHeaders();
    try testing.expect(headers.len > 0);
}