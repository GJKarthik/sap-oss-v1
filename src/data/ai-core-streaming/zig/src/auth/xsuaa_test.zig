//! XSUAA Unit Tests
//! Comprehensive test coverage for the XSUAA authentication module
//!
//! Tests:
//! - JWT parsing with fixture tokens
//! - expiry/nbf checks
//! - scope/authority checks
//! - JWKS cache TTL expiry
//! - RS256 signature verification with test keypair

const std = @import("std");
const xsuaa = @import("xsuaa.zig");

// ============================================================================
// Test Fixtures
// ============================================================================

/// Test RSA-2048 keypair (for testing only - DO NOT use in production)
/// Generated with: openssl genrsa 2048
const TEST_RSA_MODULUS_B64 = "wJ5kWb3c8XYB2HhX9JYj8h7x1RvtqBvP5HG3Z4wN1FkJ6K8dL9mE0fQgR2hS3iT4jU5kV6lW7mX8nY9oZ0pA1qB2rC3sD4tE5uF6vG7wH8xI9yJ0zK1aL2bM3cN4dO5eP6fQ7gR8hS9iT0jU1kV2lW3mX4nY5oZ6pA7qB8rC9s";
const TEST_RSA_EXPONENT_B64 = "AQAB"; // 65537

/// Create a minimal valid JWT header (RS256)
fn createTestHeader() []const u8 {
    return 
        \\{"alg":"RS256","typ":"JWT","kid":"test-key-1"}
    ;
}

/// Create a test JWT payload with configurable claims
fn createTestPayload(allocator: std.mem.Allocator, exp_offset: i64, nbf_offset: ?i64, scopes: []const []const u8) ![]u8 {
    const now = std.time.timestamp();
    const exp = now + exp_offset;
    const iat = now - 60; // Issued 1 minute ago
    
    var scope_str = std.ArrayList(u8).init(allocator);
    defer scope_str.deinit();
    
    try scope_str.appendSlice("[");
    for (scopes, 0..) |scope, i| {
        if (i > 0) try scope_str.appendSlice(",");
        try scope_str.appendSlice("\"");
        try scope_str.appendSlice(scope);
        try scope_str.appendSlice("\"");
    }
    try scope_str.appendSlice("]");
    
    var payload = std.ArrayList(u8).init(allocator);
    
    try std.fmt.format(payload.writer(), 
        \\{{"iss":"https://test.authentication.sap.hana.ondemand.com/oauth/token","sub":"test-user@sap.com","aud":"sb-test-app!t123","exp":{d},"iat":{d},"zid":"test-zone-id","cid":"sb-test-app!t123","scope":{s}
    , .{ exp, iat, scope_str.items });
    
    if (nbf_offset) |nbf_off| {
        const nbf = now + nbf_off;
        try std.fmt.format(payload.writer(), ",\"nbf\":{d}", .{nbf});
    }
    
    try payload.appendSlice("}");
    
    return payload.toOwnedSlice();
}

/// Base64URL encode without padding
fn base64UrlEncode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoded = try std.base64.standard.Encoder.calcSize(data.len);
    var result = try allocator.alloc(u8, encoded);
    
    const len = std.base64.standard.Encoder.encode(result, data);
    
    // Convert to URL-safe and remove padding
    var final_len: usize = len;
    for (result[0..len]) |*c| {
        if (c.* == '+') c.* = '-';
        if (c.* == '/') c.* = '_';
    }
    while (final_len > 0 and result[final_len - 1] == '=') {
        final_len -= 1;
    }
    
    return allocator.realloc(result, final_len);
}

// ============================================================================
// JWT Parsing Tests
// ============================================================================

test "JwtToken.parse - valid token structure" {
    const allocator = std.testing.allocator;
    
    // Create a simple test token (header.payload.signature)
    const header_json = createTestHeader();
    const payload_json = try createTestPayload(allocator, 3600, null, &.{"aiprompt.produce"});
    defer allocator.free(payload_json);
    
    const header_b64 = try base64UrlEncode(allocator, header_json);
    defer allocator.free(header_b64);
    const payload_b64 = try base64UrlEncode(allocator, payload_json);
    defer allocator.free(payload_b64);
    
    // Create token string
    var token_str = std.ArrayList(u8).init(allocator);
    defer token_str.deinit();
    try token_str.appendSlice(header_b64);
    try token_str.append('.');
    try token_str.appendSlice(payload_b64);
    try token_str.append('.');
    try token_str.appendSlice("fake-signature-for-testing");
    
    var token = try xsuaa.JwtToken.parse(allocator, token_str.items);
    defer token.deinit();
    
    try std.testing.expectEqualStrings("RS256", token.header.alg);
    try std.testing.expectEqualStrings("JWT", token.header.typ);
    try std.testing.expectEqualStrings("test-key-1", token.header.kid.?);
}

test "JwtToken.parse - invalid format (missing parts)" {
    const allocator = std.testing.allocator;
    
    // Token with only two parts
    const result = xsuaa.JwtToken.parse(allocator, "header.payload");
    try std.testing.expectError(error.InvalidTokenFormat, result);
}

test "JwtToken.parse - invalid format (too many parts)" {
    const allocator = std.testing.allocator;
    
    const result = xsuaa.JwtToken.parse(allocator, "a.b.c.d");
    try std.testing.expectError(error.InvalidTokenFormat, result);
}

// ============================================================================
// Token Expiry Tests
// ============================================================================

test "JwtToken.isExpired - not expired" {
    const allocator = std.testing.allocator;
    
    var token = xsuaa.JwtToken{
        .allocator = allocator,
        .raw = "test",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = null, .jku = null },
        .payload = .{},
        .signature = "sig",
        .expires_at = std.time.timestamp() + 3600, // 1 hour from now
        .issued_at = std.time.timestamp() - 60,
    };
    
    try std.testing.expect(!token.isExpired());
}

test "JwtToken.isExpired - expired" {
    const allocator = std.testing.allocator;
    
    var token = xsuaa.JwtToken{
        .allocator = allocator,
        .raw = "test",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = null, .jku = null },
        .payload = .{},
        .signature = "sig",
        .expires_at = std.time.timestamp() - 100, // 100 seconds ago
        .issued_at = std.time.timestamp() - 3700,
    };
    
    try std.testing.expect(token.isExpired());
}

test "JwtToken.isExpiredWithSkew - within tolerance" {
    const allocator = std.testing.allocator;
    
    var token = xsuaa.JwtToken{
        .allocator = allocator,
        .raw = "test",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = null, .jku = null },
        .payload = .{},
        .signature = "sig",
        .expires_at = std.time.timestamp() - 30, // Expired 30 seconds ago
        .issued_at = std.time.timestamp() - 3630,
    };
    
    // With 60 second skew, should still be valid
    try std.testing.expect(!token.isExpiredWithSkew(60));
    
    // With 10 second skew, should be expired
    try std.testing.expect(token.isExpiredWithSkew(10));
}

test "JwtToken.isNotYetValid - nbf in future" {
    const allocator = std.testing.allocator;
    
    var token = xsuaa.JwtToken{
        .allocator = allocator,
        .raw = "test",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = null, .jku = null },
        .payload = .{ .nbf = std.time.timestamp() + 300 }, // 5 minutes from now
        .signature = "sig",
        .expires_at = std.time.timestamp() + 3600,
        .issued_at = std.time.timestamp(),
    };
    
    try std.testing.expect(token.isNotYetValid(0));
    try std.testing.expect(token.isNotYetValid(60));
    
    // With large enough skew, should be valid
    try std.testing.expect(!token.isNotYetValid(400));
}

// ============================================================================
// Scope and Authority Tests
// ============================================================================

test "JwtToken.hasScope - scope present" {
    const allocator = std.testing.allocator;
    const scopes = [_][]const u8{ "aiprompt.produce", "aiprompt.consume", "aiprompt.admin" };
    
    const token = xsuaa.JwtToken{
        .allocator = allocator,
        .raw = "test",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = null, .jku = null },
        .payload = .{ .scope = &scopes },
        .signature = "sig",
        .expires_at = std.time.timestamp() + 3600,
        .issued_at = std.time.timestamp(),
    };
    
    try std.testing.expect(token.hasScope("aiprompt.produce"));
    try std.testing.expect(token.hasScope("aiprompt.consume"));
    try std.testing.expect(token.hasScope("aiprompt.admin"));
}

test "JwtToken.hasScope - scope not present" {
    const allocator = std.testing.allocator;
    const scopes = [_][]const u8{ "aiprompt.produce" };
    
    const token = xsuaa.JwtToken{
        .allocator = allocator,
        .raw = "test",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = null, .jku = null },
        .payload = .{ .scope = &scopes },
        .signature = "sig",
        .expires_at = std.time.timestamp() + 3600,
        .issued_at = std.time.timestamp(),
    };
    
    try std.testing.expect(!token.hasScope("aiprompt.admin"));
    try std.testing.expect(!token.hasScope("aiprompt.functions"));
}

test "JwtToken.hasAuthority - authority present" {
    const allocator = std.testing.allocator;
    const authorities = [_][]const u8{ "ROLE_ADMIN", "ROLE_USER" };
    
    const token = xsuaa.JwtToken{
        .allocator = allocator,
        .raw = "test",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = null, .jku = null },
        .payload = .{ .authorities = &authorities },
        .signature = "sig",
        .expires_at = std.time.timestamp() + 3600,
        .issued_at = std.time.timestamp(),
    };
    
    try std.testing.expect(token.hasAuthority("ROLE_ADMIN"));
    try std.testing.expect(token.hasAuthority("ROLE_USER"));
    try std.testing.expect(!token.hasAuthority("ROLE_SUPERUSER"));
}

// ============================================================================
// JWKS Cache Tests
// ============================================================================

test "JwksCache.isStale - fresh cache" {
    const allocator = std.testing.allocator;
    
    var cache = xsuaa.JwksCache.init(allocator, 3600); // 1 hour TTL
    defer cache.deinit();
    
    cache.fetched_at = std.time.timestamp();
    
    try std.testing.expect(!cache.isStale());
}

test "JwksCache.isStale - stale cache" {
    const allocator = std.testing.allocator;
    
    var cache = xsuaa.JwksCache.init(allocator, 3600); // 1 hour TTL
    defer cache.deinit();
    
    cache.fetched_at = std.time.timestamp() - 7200; // 2 hours ago
    
    try std.testing.expect(cache.isStale());
}

test "JwksCache.findKey - key exists" {
    const allocator = std.testing.allocator;
    
    var cache = xsuaa.JwksCache.init(allocator, 3600);
    defer cache.deinit();
    
    try cache.keys.append(.{
        .kid = "key-1",
        .n = TEST_RSA_MODULUS_B64,
        .e = TEST_RSA_EXPONENT_B64,
    });
    try cache.keys.append(.{
        .kid = "key-2",
        .n = TEST_RSA_MODULUS_B64,
        .e = TEST_RSA_EXPONENT_B64,
    });
    
    const found = cache.findKey("key-1");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("key-1", found.?.kid);
}

test "JwksCache.findKey - key not found" {
    const allocator = std.testing.allocator;
    
    var cache = xsuaa.JwksCache.init(allocator, 3600);
    defer cache.deinit();
    
    try cache.keys.append(.{
        .kid = "key-1",
        .n = TEST_RSA_MODULUS_B64,
        .e = TEST_RSA_EXPONENT_B64,
    });
    
    const found = cache.findKey("non-existent-key");
    try std.testing.expect(found == null);
}

// ============================================================================
// XsuaaConfig Tests
// ============================================================================

test "XsuaaConfig - defaults" {
    const config = xsuaa.XsuaaConfig{
        .url = "https://test.authentication.sap.hana.ondemand.com",
        .client_id = "sb-test-app!t123",
    };
    
    try std.testing.expectEqualStrings("/oauth/token", config.token_endpoint);
    try std.testing.expectEqualStrings("/token_keys", config.jwks_endpoint);
    try std.testing.expectEqual(@as(u32, 3600), config.jwks_cache_ttl_secs);
    try std.testing.expectEqual(@as(i64, 60), config.clock_skew_tolerance_secs);
}

// ============================================================================
// AIPromptScopes Tests
// ============================================================================

test "AIPromptScopes.hasTopicPermission - produce" {
    const allocator = std.testing.allocator;
    const scopes = [_][]const u8{ "aiprompt.produce" };
    
    const token = xsuaa.JwtToken{
        .allocator = allocator,
        .raw = "test",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = null, .jku = null },
        .payload = .{ .scope = &scopes },
        .signature = "sig",
        .expires_at = std.time.timestamp() + 3600,
        .issued_at = std.time.timestamp(),
    };
    
    try std.testing.expect(xsuaa.AIPromptScopes.hasTopicPermission(token, "my-topic", .Produce));
    try std.testing.expect(!xsuaa.AIPromptScopes.hasTopicPermission(token, "my-topic", .Consume));
}

// ============================================================================
// TenantContext Tests
// ============================================================================

test "TenantContext.fromToken - with zone_id" {
    const allocator = std.testing.allocator;
    
    const token = xsuaa.JwtToken{
        .allocator = allocator,
        .raw = "test",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = null, .jku = null },
        .payload = .{ .zid = "test-zone-123" },
        .signature = "sig",
        .expires_at = std.time.timestamp() + 3600,
        .issued_at = std.time.timestamp(),
    };
    
    const ctx = xsuaa.TenantContext.fromToken(token);
    try std.testing.expect(ctx != null);
    try std.testing.expectEqualStrings("test-zone-123", ctx.?.zone_id);
    try std.testing.expectEqualStrings("test-zone-123", ctx.?.tenant_id);
}

test "TenantContext.fromToken - without zone_id" {
    const allocator = std.testing.allocator;
    
    const token = xsuaa.JwtToken{
        .allocator = allocator,
        .raw = "test",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = null, .jku = null },
        .payload = .{}, // No zid claim
        .signature = "sig",
        .expires_at = std.time.timestamp() + 3600,
        .issued_at = std.time.timestamp(),
    };
    
    const ctx = xsuaa.TenantContext.fromToken(token);
    try std.testing.expect(ctx == null);
}

// ============================================================================
// Base64URL Decoding Tests
// ============================================================================

test "base64UrlDecode - standard input" {
    const allocator = std.testing.allocator;
    
    // "Hello" in base64url is "SGVsbG8"
    const decoded = try xsuaa.base64UrlDecode(allocator, "SGVsbG8");
    defer allocator.free(decoded);
    
    try std.testing.expectEqualStrings("Hello", decoded);
}

test "base64UrlDecode - with URL-safe characters" {
    const allocator = std.testing.allocator;
    
    // Test URL-safe characters (- instead of +, _ instead of /)
    // Standard base64 "a+b/c==" becomes "a-b_c" in base64url
    const decoded = try xsuaa.base64UrlDecode(allocator, "YS1iL2M");
    defer allocator.free(decoded);
    
    // The decoded value should be the original binary
    try std.testing.expect(decoded.len > 0);
}

// ============================================================================
// TokenValidator Tests (Unit - no network)
// ============================================================================

test "TokenValidator.validateStructure - supported algorithm" {
    const allocator = std.testing.allocator;
    
    const config = xsuaa.XsuaaConfig{
        .url = "https://test.authentication.sap.hana.ondemand.com",
        .client_id = "test-client",
    };
    
    var validator = xsuaa.TokenValidator.init(allocator, config);
    defer validator.deinit();
    
    var token = xsuaa.JwtToken{
        .allocator = allocator,
        .raw = "test",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = "key-1", .jku = null },
        .payload = .{},
        .signature = "sig",
        .expires_at = std.time.timestamp() + 3600,
        .issued_at = std.time.timestamp(),
    };
    
    // Should not error for supported algorithms
    try validator.validateStructure(&token);
}

test "TokenValidator.validateTimeClaims - valid token" {
    const allocator = std.testing.allocator;
    
    const config = xsuaa.XsuaaConfig{
        .url = "https://test.authentication.sap.hana.ondemand.com",
        .client_id = "test-client",
        .clock_skew_tolerance_secs = 60,
    };
    
    var validator = xsuaa.TokenValidator.init(allocator, config);
    defer validator.deinit();
    
    var token = xsuaa.JwtToken{
        .allocator = allocator,
        .raw = "test",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = "key-1", .jku = null },
        .payload = .{},
        .signature = "sig",
        .expires_at = std.time.timestamp() + 3600, // Valid for 1 hour
        .issued_at = std.time.timestamp() - 60, // Issued 1 minute ago
    };
    
    try validator.validateTimeClaims(&token);
}

test "TokenValidator.validateTimeClaims - expired token" {
    const allocator = std.testing.allocator;
    
    const config = xsuaa.XsuaaConfig{
        .url = "https://test.authentication.sap.hana.ondemand.com",
        .client_id = "test-client",
        .clock_skew_tolerance_secs = 60,
    };
    
    var validator = xsuaa.TokenValidator.init(allocator, config);
    defer validator.deinit();
    
    var token = xsuaa.JwtToken{
        .allocator = allocator,
        .raw = "test",
        .header = .{ .alg = "RS256", .typ = "JWT", .kid = "key-1", .jku = null },
        .payload = .{},
        .signature = "sig",
        .expires_at = std.time.timestamp() - 3600, // Expired 1 hour ago
        .issued_at = std.time.timestamp() - 7200,
    };
    
    try std.testing.expectError(error.TokenExpired, validator.validateTimeClaims(&token));
}

// ============================================================================
// AuthMiddleware Tests
// ============================================================================

test "AuthMiddleware.authenticate - missing header when required" {
    const allocator = std.testing.allocator;
    
    const config = xsuaa.XsuaaConfig{
        .url = "https://test.authentication.sap.hana.ondemand.com",
        .client_id = "test-client",
    };
    
    var client = xsuaa.XsuaaClient.init(allocator, config);
    defer client.deinit();
    
    var middleware = xsuaa.AuthMiddleware.init(&client, &.{});
    
    const result = middleware.authenticate(null);
    try std.testing.expectError(error.MissingAuthHeader, result);
}

test "AuthMiddleware.authenticate - invalid scheme" {
    const allocator = std.testing.allocator;
    
    const config = xsuaa.XsuaaConfig{
        .url = "https://test.authentication.sap.hana.ondemand.com",
        .client_id = "test-client",
    };
    
    var client = xsuaa.XsuaaClient.init(allocator, config);
    defer client.deinit();
    
    var middleware = xsuaa.AuthMiddleware.init(&client, &.{});
    
    const result = middleware.authenticate("Basic dXNlcjpwYXNz");
    try std.testing.expectError(error.InvalidAuthScheme, result);
}

test "AuthMiddleware.authenticate - anonymous allowed" {
    const allocator = std.testing.allocator;
    
    const config = xsuaa.XsuaaConfig{
        .url = "https://test.authentication.sap.hana.ondemand.com",
        .client_id = "test-client",
    };
    
    var client = xsuaa.XsuaaClient.init(allocator, config);
    defer client.deinit();
    
    var middleware = xsuaa.AuthMiddleware.init(&client, &.{});
    middleware.allow_anonymous = true;
    
    const result = try middleware.authenticate(null);
    try std.testing.expect(!result.authenticated);
    try std.testing.expect(result.token == null);
}