const std = @import("std");

pub const Config = struct {
    port: u16,
    host: []const u8,
    pal_sdk_path: []const u8,
    hana_host: []const u8,
    hana_port: u16,
    hana_user: []const u8,
    hana_password: []const u8,
    hana_database: []const u8,
    hana_schema: []const u8,
    search_svc_url: []const u8,
    search_svc_path: []const u8,
    deductive_db_url: []const u8,
    odata_service_url: []const u8,
    log_level: LogLevel,

    pub const LogLevel = enum { debug, info, warn, err };

    pub fn fromEnv(allocator: std.mem.Allocator) Config {
        _ = allocator;
        return .{
            .port = getEnvPort(9881),
            .host = getEnvStr("MCPPAL_HOST", "0.0.0.0"),
            .pal_sdk_path = getEnvStr("PAL_SDK_PATH", "../../../aiNucleusSdk/ainuc-sap-sdk/sap-pal-webcomponents-sql"),
            .hana_host = getEnvStr("HANA_HOST", "localhost"),
            .hana_port = getEnvU16("HANA_PORT", 443),
            .hana_user = getEnvStr("HANA_USER", ""),
            .hana_password = getEnvStr("HANA_PASSWORD", ""),
            .hana_database = getEnvStr("HANA_DATABASE", ""),
            .hana_schema = getEnvStr("HANA_SCHEMA", ""),
            .search_svc_url = getEnvStr("SEARCH_SVC_URL", "http://localhost:8080"),
            .search_svc_path = getEnvStr("SEARCH_SVC_PATH", "../../../ainuc-be-log/ainuc-be-log-search-svc"),
            .deductive_db_url = getEnvStr("DEDUCTIVE_DB_URL", "http://localhost:8080"),
            .odata_service_url = getEnvStr("ODATA_SERVICE_URL", ""),
            .log_level = getEnvLogLevel("MCPPAL_LOG_LEVEL", .info),
        };
    }

    fn getEnvStr(key: []const u8, default: []const u8) []const u8 {
        return std.posix.getenv(key) orelse default;
    }

    fn getEnvU16(key: []const u8, default: u16) u16 {
        const val = std.posix.getenv(key) orelse return default;
        return std.fmt.parseInt(u16, val, 10) catch default;
    }

    fn getEnvPort(default: u16) u16 {
        const explicit = std.posix.getenv("MCPPAL_PORT");
        if (explicit) |val| {
            return std.fmt.parseInt(u16, val, 10) catch default;
        }

        const alias = std.posix.getenv("MCP_PORT");
        if (alias) |val| {
            return std.fmt.parseInt(u16, val, 10) catch default;
        }

        return default;
    }

    fn getEnvLogLevel(key: []const u8, default: LogLevel) LogLevel {
        const val = std.posix.getenv(key) orelse return default;
        if (std.mem.eql(u8, val, "debug")) return .debug;
        if (std.mem.eql(u8, val, "warn")) return .warn;
        if (std.mem.eql(u8, val, "error")) return .err;
        return default;
    }
};
