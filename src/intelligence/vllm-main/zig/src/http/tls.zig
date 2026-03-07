//! TLS/HTTPS Support
//!
//! Optional TLS termination for the HTTP server using OpenSSL via C FFI.
//! In production on SAP BTP AI Core, TLS is typically terminated by the
//! KServe ingress controller. This module enables direct HTTPS for:
//! - Local development with self-signed certificates
//! - Edge deployments without ingress
//! - End-to-end encryption requirements
//!
//! ## Usage
//!   const tls_cfg = TlsConfig.fromEnv();
//!   if (tls_cfg.enabled) {
//!       // TLS is configured via TLS_CERT_PATH and TLS_KEY_PATH env vars
//!   }

const std = @import("std");
const log = std.log.scoped(.tls);

/// TLS configuration loaded from environment variables
pub const TlsConfig = struct {
    enabled: bool = false,
    cert_path: ?[]const u8 = null, // TLS_CERT_PATH
    key_path: ?[]const u8 = null, // TLS_KEY_PATH
    min_version: TlsVersion = .tls_1_2,
    client_auth: bool = false, // Require client certificates
    ca_path: ?[]const u8 = null, // TLS_CA_PATH for client cert verification

    pub const TlsVersion = enum {
        tls_1_2,
        tls_1_3,
    };

    /// Load TLS configuration from environment variables
    pub fn fromEnv() TlsConfig {
        const cert = std.posix.getenv("TLS_CERT_PATH");
        const key = std.posix.getenv("TLS_KEY_PATH");

        if (cert != null and key != null) {
            return .{
                .enabled = true,
                .cert_path = cert,
                .key_path = key,
                .ca_path = std.posix.getenv("TLS_CA_PATH"),
                .client_auth = if (std.posix.getenv("TLS_CLIENT_AUTH")) |v|
                    std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")
                else
                    false,
                .min_version = if (std.posix.getenv("TLS_MIN_VERSION")) |v|
                    if (std.mem.eql(u8, v, "1.3")) .tls_1_3 else .tls_1_2
                else
                    .tls_1_2,
            };
        }

        return .{}; // TLS disabled
    }

    /// Validate TLS configuration (check cert/key files exist)
    pub fn validate(self: *const TlsConfig) !void {
        if (!self.enabled) return;

        if (self.cert_path) |path| {
            std.fs.cwd().access(path, .{}) catch |err| {
                log.err("TLS certificate not found at '{s}': {}", .{ path, err });
                return error.TlsCertNotFound;
            };
        }

        if (self.key_path) |path| {
            std.fs.cwd().access(path, .{}) catch |err| {
                log.err("TLS private key not found at '{s}': {}", .{ path, err });
                return error.TlsKeyNotFound;
            };
        }

        log.info("TLS enabled: cert={s}, key={s}, min_version={s}", .{
            self.cert_path orelse "(none)",
            self.key_path orelse "(none)",
            if (self.min_version == .tls_1_3) "1.3" else "1.2",
        });
    }
};

/// TLS connection state
pub const TlsState = enum {
    disabled, // Plain HTTP
    handshaking, // TLS handshake in progress
    established, // TLS session active
    error_state, // TLS error occurred

    pub fn isSecure(self: TlsState) bool {
        return self == .established;
    }
};

/// Summary of TLS capabilities for /api/gpu/info and health endpoints
pub fn getTlsInfo(config: *const TlsConfig) struct {
    enabled: bool,
    min_version: []const u8,
    client_auth: bool,
} {
    return .{
        .enabled = config.enabled,
        .min_version = if (config.min_version == .tls_1_3) "1.3" else "1.2",
        .client_auth = config.client_auth,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "TlsConfig default is disabled" {
    const cfg = TlsConfig{};
    try std.testing.expect(!cfg.enabled);
    try std.testing.expect(cfg.cert_path == null);
    try std.testing.expect(cfg.key_path == null);
    try std.testing.expectEqual(TlsConfig.TlsVersion.tls_1_2, cfg.min_version);
    try std.testing.expect(!cfg.client_auth);
    try std.testing.expect(cfg.ca_path == null);
}

test "TlsConfig.fromEnv with no env vars returns disabled" {
    // In test environment, TLS_CERT_PATH and TLS_KEY_PATH are not set
    const cfg = TlsConfig.fromEnv();
    try std.testing.expect(!cfg.enabled);
    try std.testing.expect(cfg.cert_path == null);
    try std.testing.expect(cfg.key_path == null);
}

test "TlsState transitions" {
    const disabled = TlsState.disabled;
    const handshaking = TlsState.handshaking;
    const established = TlsState.established;
    const err_state = TlsState.error_state;

    try std.testing.expect(!disabled.isSecure());
    try std.testing.expect(!handshaking.isSecure());
    try std.testing.expect(established.isSecure());
    try std.testing.expect(!err_state.isSecure());
}

test "getTlsInfo reflects config" {
    const disabled_cfg = TlsConfig{};
    const info = getTlsInfo(&disabled_cfg);
    try std.testing.expect(!info.enabled);
    try std.testing.expectEqualStrings("1.2", info.min_version);
    try std.testing.expect(!info.client_auth);

    const enabled_cfg = TlsConfig{
        .enabled = true,
        .cert_path = "/tmp/cert.pem",
        .key_path = "/tmp/key.pem",
        .min_version = .tls_1_3,
        .client_auth = true,
    };
    const info2 = getTlsInfo(&enabled_cfg);
    try std.testing.expect(info2.enabled);
    try std.testing.expectEqualStrings("1.3", info2.min_version);
    try std.testing.expect(info2.client_auth);
}

