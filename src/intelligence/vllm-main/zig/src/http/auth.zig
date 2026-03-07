//! API Key Authentication
//! Validates Bearer token from Authorization header against API_KEY env var

const std = @import("std");

const http = @import("server.zig");
const log = std.log.scoped(.auth);

/// Validate API key from http.Request
pub fn validateApiKey(req: *http.Request, expected_key: []const u8) bool {
    const auth_header = req.headers.get("Authorization") orelse 
                       req.headers.get("authorization") orelse return false;
    return validateAuth(auth_header, expected_key);
}

/// Check if a request path requires authentication
pub fn requiresAuth(path: []const u8) bool {
    // Skip auth for health/ready/metrics endpoints
    if (std.mem.eql(u8, path, "/health")) return false;
    if (std.mem.eql(u8, path, "/healthz")) return false;
    if (std.mem.eql(u8, path, "/ready")) return false;
    if (std.mem.eql(u8, path, "/readyz")) return false;
    if (std.mem.eql(u8, path, "/metrics")) return false;
    return true;
}

/// Constant-time byte comparison.  Note: the early `a.len != b.len` return
/// leaks the *length* of the expected key via timing, but not its content.
/// For Bearer-token auth this is acceptable (the token format is public).
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Validate authorization header against expected API key
pub fn validateAuth(auth_header: ?[]const u8, expected_key: []const u8) bool {
    const header = auth_header orelse return false;

    // Expect "Bearer <token>"
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, header, prefix)) return false;

    const token = header[prefix.len..];
    return constantTimeEql(token, expected_key);
}

/// Extract API key from environment
pub fn getApiKeyFromEnv() ?[]const u8 {
    return std.posix.getenv("API_KEY");
}

test "requiresAuth skips health endpoints" {
    try std.testing.expect(!requiresAuth("/health"));
    try std.testing.expect(!requiresAuth("/ready"));
    try std.testing.expect(!requiresAuth("/metrics"));
    try std.testing.expect(requiresAuth("/api/v1/embed"));
    try std.testing.expect(requiresAuth("/api/v1/chat"));
    try std.testing.expect(requiresAuth("/api/v1/search"));
}

test "validateAuth accepts valid bearer token" {
    try std.testing.expect(validateAuth("Bearer my-secret-key", "my-secret-key"));
}

test "validateAuth rejects invalid token" {
    try std.testing.expect(!validateAuth("Bearer wrong-key", "my-secret-key"));
    try std.testing.expect(!validateAuth(null, "my-secret-key"));
    try std.testing.expect(!validateAuth("Basic abc123", "my-secret-key"));
    try std.testing.expect(!validateAuth("Bearertoken", "token")); // Missing space
    try std.testing.expect(!validateAuth("", "my-secret-key"));
}