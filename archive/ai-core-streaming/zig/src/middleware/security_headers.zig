//! Security Headers Middleware
//!
//! Implements standard security headers recommended by OWASP:
//! - Content-Security-Policy (CSP)
//! - X-Content-Type-Options
//! - X-Frame-Options
//! - X-XSS-Protection
//! - Strict-Transport-Security (HSTS)
//! - Referrer-Policy
//! - Permissions-Policy

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Security headers configuration
pub const SecurityHeadersConfig = struct {
    /// Enable HSTS (Strict-Transport-Security)
    enable_hsts: bool = true,
    /// HSTS max-age in seconds (default: 1 year)
    hsts_max_age: u32 = 31536000,
    /// Include subdomains in HSTS
    hsts_include_subdomains: bool = true,
    /// Enable HSTS preload
    hsts_preload: bool = false,

    /// X-Frame-Options: DENY, SAMEORIGIN, or null to disable
    frame_options: ?FrameOption = .deny,

    /// X-Content-Type-Options: nosniff
    content_type_options: bool = true,

    /// X-XSS-Protection (legacy, but still useful)
    xss_protection: bool = true,

    /// Referrer-Policy
    referrer_policy: ReferrerPolicy = .strict_origin_when_cross_origin,

    /// Content-Security-Policy
    csp_enabled: bool = true,
    csp_report_only: bool = false,
    csp_directives: ?[]const u8 = null,

    /// Permissions-Policy (formerly Feature-Policy)
    permissions_policy: ?[]const u8 = null,

    /// Cache-Control for API responses
    cache_control: ?[]const u8 = "no-store, no-cache, must-revalidate",

    /// Cross-Origin-Embedder-Policy
    coep: ?[]const u8 = "require-corp",

    /// Cross-Origin-Opener-Policy  
    coop: ?[]const u8 = "same-origin",

    /// Cross-Origin-Resource-Policy
    corp: ?[]const u8 = "same-origin",
};

pub const FrameOption = enum {
    deny,
    sameorigin,
};

pub const ReferrerPolicy = enum {
    no_referrer,
    no_referrer_when_downgrade,
    origin,
    origin_when_cross_origin,
    same_origin,
    strict_origin,
    strict_origin_when_cross_origin,
    unsafe_url,

    pub fn toString(self: ReferrerPolicy) []const u8 {
        return switch (self) {
            .no_referrer => "no-referrer",
            .no_referrer_when_downgrade => "no-referrer-when-downgrade",
            .origin => "origin",
            .origin_when_cross_origin => "origin-when-cross-origin",
            .same_origin => "same-origin",
            .strict_origin => "strict-origin",
            .strict_origin_when_cross_origin => "strict-origin-when-cross-origin",
            .unsafe_url => "unsafe-url",
        };
    }
};

/// Security headers middleware
pub const SecurityHeaders = struct {
    config: SecurityHeadersConfig,
    allocator: Allocator,
    cached_headers: ?[]const u8,

    const Self = @This();

    pub fn init(allocator: Allocator, config: SecurityHeadersConfig) Self {
        return Self{
            .config = config,
            .allocator = allocator,
            .cached_headers = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.cached_headers) |h| {
            self.allocator.free(h);
        }
    }

    /// Get default CSP for API services
    fn defaultCsp() []const u8 {
        return 
            \\default-src 'none'; 
            \\script-src 'none'; 
            \\style-src 'none'; 
            \\img-src 'none'; 
            \\font-src 'none'; 
            \\connect-src 'self'; 
            \\frame-ancestors 'none'; 
            \\base-uri 'none'; 
            \\form-action 'none'
        ;
    }

    /// Default permissions policy for API services
    fn defaultPermissionsPolicy() []const u8 {
        return 
            \\accelerometer=(), 
            \\camera=(), 
            \\geolocation=(), 
            \\gyroscope=(), 
            \\magnetometer=(), 
            \\microphone=(), 
            \\payment=(), 
            \\usb=()
        ;
    }

    /// Generate all security headers as a string
    pub fn getHeaders(self: *Self) ![]const u8 {
        // Return cached version if available
        if (self.cached_headers) |h| {
            return h;
        }

        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        // HSTS
        if (self.config.enable_hsts) {
            try writer.print("Strict-Transport-Security: max-age={d}", .{self.config.hsts_max_age});
            if (self.config.hsts_include_subdomains) {
                try writer.writeAll("; includeSubDomains");
            }
            if (self.config.hsts_preload) {
                try writer.writeAll("; preload");
            }
            try writer.writeAll("\r\n");
        }

        // X-Frame-Options
        if (self.config.frame_options) |opt| {
            const value = switch (opt) {
                .deny => "DENY",
                .sameorigin => "SAMEORIGIN",
            };
            try writer.print("X-Frame-Options: {s}\r\n", .{value});
        }

        // X-Content-Type-Options
        if (self.config.content_type_options) {
            try writer.writeAll("X-Content-Type-Options: nosniff\r\n");
        }

        // X-XSS-Protection
        if (self.config.xss_protection) {
            try writer.writeAll("X-XSS-Protection: 1; mode=block\r\n");
        }

        // Referrer-Policy
        try writer.print("Referrer-Policy: {s}\r\n", .{self.config.referrer_policy.toString()});

        // Content-Security-Policy
        if (self.config.csp_enabled) {
            const header_name = if (self.config.csp_report_only)
                "Content-Security-Policy-Report-Only"
            else
                "Content-Security-Policy";

            const csp = self.config.csp_directives orelse defaultCsp();
            try writer.print("{s}: {s}\r\n", .{ header_name, csp });
        }

        // Permissions-Policy
        const permissions = self.config.permissions_policy orelse defaultPermissionsPolicy();
        try writer.print("Permissions-Policy: {s}\r\n", .{permissions});

        // Cache-Control
        if (self.config.cache_control) |cc| {
            try writer.print("Cache-Control: {s}\r\n", .{cc});
        }

        // Cross-Origin policies
        if (self.config.coep) |coep| {
            try writer.print("Cross-Origin-Embedder-Policy: {s}\r\n", .{coep});
        }
        if (self.config.coop) |coop| {
            try writer.print("Cross-Origin-Opener-Policy: {s}\r\n", .{coop});
        }
        if (self.config.corp) |corp| {
            try writer.print("Cross-Origin-Resource-Policy: {s}\r\n", .{corp});
        }

        // Additional recommended headers
        try writer.writeAll("X-DNS-Prefetch-Control: off\r\n");
        try writer.writeAll("X-Download-Options: noopen\r\n");
        try writer.writeAll("X-Permitted-Cross-Domain-Policies: none\r\n");

        const result = try buf.toOwnedSlice();
        self.cached_headers = result;
        return result;
    }

    /// Apply headers to an HTTP response (for integration with HTTP servers)
    pub fn applyToResponse(self: *Self, response: anytype) !void {
        const headers = try self.getHeaders();

        // Parse headers and apply to response
        var it = std.mem.splitSequence(u8, headers, "\r\n");
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.indexOf(u8, line, ": ")) |idx| {
                const name = line[0..idx];
                const value = line[idx + 2 ..];
                try response.setHeader(name, value);
            }
        }
    }
};

/// CORS configuration
pub const CorsConfig = struct {
    /// Allowed origins (null = deny all, "*" = allow all)
    allowed_origins: ?[]const []const u8 = null,
    /// Allowed methods
    allowed_methods: []const []const u8 = &.{ "GET", "POST", "OPTIONS" },
    /// Allowed headers
    allowed_headers: []const []const u8 = &.{ "Content-Type", "Authorization" },
    /// Exposed headers
    exposed_headers: []const []const u8 = &.{},
    /// Allow credentials
    allow_credentials: bool = false,
    /// Preflight cache max age
    max_age: u32 = 86400,
};

/// CORS middleware
pub const Cors = struct {
    config: CorsConfig,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator, config: CorsConfig) Self {
        return Self{
            .config = config,
            .allocator = allocator,
        };
    }

    /// Check if origin is allowed
    pub fn isOriginAllowed(self: *Self, origin: []const u8) bool {
        if (self.config.allowed_origins) |origins| {
            for (origins) |allowed| {
                if (std.mem.eql(u8, allowed, "*") or std.mem.eql(u8, allowed, origin)) {
                    return true;
                }
            }
            return false;
        }
        return false; // Deny by default
    }

    /// Generate CORS headers for a request
    pub fn getHeaders(self: *Self, origin: ?[]const u8) !?[]u8 {
        const req_origin = origin orelse return null;

        if (!self.isOriginAllowed(req_origin)) {
            return null;
        }

        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        // Access-Control-Allow-Origin
        try writer.print("Access-Control-Allow-Origin: {s}\r\n", .{req_origin});

        // Access-Control-Allow-Methods
        try writer.writeAll("Access-Control-Allow-Methods: ");
        for (self.config.allowed_methods, 0..) |method, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(method);
        }
        try writer.writeAll("\r\n");

        // Access-Control-Allow-Headers
        try writer.writeAll("Access-Control-Allow-Headers: ");
        for (self.config.allowed_headers, 0..) |header, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(header);
        }
        try writer.writeAll("\r\n");

        // Access-Control-Allow-Credentials
        if (self.config.allow_credentials) {
            try writer.writeAll("Access-Control-Allow-Credentials: true\r\n");
        }

        // Access-Control-Max-Age
        try writer.print("Access-Control-Max-Age: {d}\r\n", .{self.config.max_age});

        // Access-Control-Expose-Headers
        if (self.config.exposed_headers.len > 0) {
            try writer.writeAll("Access-Control-Expose-Headers: ");
            for (self.config.exposed_headers, 0..) |header, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(header);
            }
            try writer.writeAll("\r\n");
        }

        return try buf.toOwnedSlice();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "security headers basic" {
    var headers = SecurityHeaders.init(std.testing.allocator, .{});
    defer headers.deinit();

    const h = try headers.getHeaders();
    try std.testing.expect(std.mem.indexOf(u8, h, "X-Frame-Options: DENY") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "X-Content-Type-Options: nosniff") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "Strict-Transport-Security") != null);
}

test "cors origin check" {
    var cors = Cors.init(std.testing.allocator, .{
        .allowed_origins = &.{ "https://example.com", "https://app.example.com" },
    });

    try std.testing.expect(cors.isOriginAllowed("https://example.com"));
    try std.testing.expect(cors.isOriginAllowed("https://app.example.com"));
    try std.testing.expect(!cors.isOriginAllowed("https://evil.com"));
}

test "cors wildcard" {
    var cors = Cors.init(std.testing.allocator, .{
        .allowed_origins = &.{"*"},
    });

    try std.testing.expect(cors.isOriginAllowed("https://any-domain.com"));
}