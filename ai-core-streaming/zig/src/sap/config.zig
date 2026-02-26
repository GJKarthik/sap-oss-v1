const std = @import("std");
const mem = std.mem;

pub const Config = struct {
    port: u16,
    host: []const u8,
    odata_url: []const u8,
    odata_user: []const u8,
    odata_password: []const u8,
    odata_version: ODataVersion,
    csrf_enabled: bool,
    upstream_timeout_ms: u32,
    log_level: LogLevel,

    pub const LogLevel = enum { debug, info, warn, err };
    pub const ODataVersion = enum { v2, v4 };

    pub fn fromEnv(allocator: std.mem.Allocator) Config {
        var cfg = Config{
            .port = getEnvU16("ODATA_PORT", 9882),
            .host = getEnvStr("ODATA_HOST", "0.0.0.0"),
            .odata_url = getEnvStr("ODATA_SERVICE_URL", ""),
            .odata_user = getEnvStr("ODATA_USER", ""),
            .odata_password = std.posix.getenv("ODATA_PASSWORD") orelse "",
            .odata_version = getEnvVersion("ODATA_VERSION", .v2),
            .csrf_enabled = getEnvBool("ODATA_CSRF_ENABLED", true),
            .upstream_timeout_ms = getEnvU32("ODATA_UPSTREAM_TIMEOUT_MS", 30000),
            .log_level = getEnvLogLevel("ODATA_LOG_LEVEL", .info),
        };

        // Auto-derive OData connectivity from shared SAP config facts when env vars are missing.
        // This keeps service bootstrap aligned with existing HANA credentials in .vscode/sap_config.mg.
        if (cfg.odata_url.len == 0 or cfg.odata_user.len == 0 or cfg.odata_password.len == 0) {
            if (getSapConfig(allocator)) |sap_cfg| {
                if (cfg.odata_url.len == 0) {
                    if (parseFactValue(sap_cfg.content, "odata_credential", "service_url")) |v| {
                        cfg.odata_url = v;
                    } else if (parseFactValue(sap_cfg.content, "hana_credential", "host")) |host| {
                        const port = parseFactValue(sap_cfg.content, "hana_credential", "port") orelse "443";
                        const encrypt = parseFactValue(sap_cfg.content, "hana_credential", "encrypt") orelse "true";
                        const scheme = if (std.ascii.eqlIgnoreCase(encrypt, "false") or mem.eql(u8, encrypt, "0")) "http" else "https";
                        cfg.odata_url = std.fmt.allocPrint(allocator, "{s}://{s}:{s}", .{ scheme, host, port }) catch cfg.odata_url;
                    }
                }
                if (cfg.odata_user.len == 0) {
                    if (parseFactValue(sap_cfg.content, "odata_credential", "user")) |v| {
                        cfg.odata_user = v;
                    } else if (parseFactValue(sap_cfg.content, "hana_credential", "user")) |v| {
                        cfg.odata_user = v;
                    }
                }
                if (cfg.odata_password.len == 0) {
                    if (parseFactValue(sap_cfg.content, "odata_credential", "password")) |v| {
                        cfg.odata_password = v;
                    } else if (parseFactValue(sap_cfg.content, "hana_credential", "password")) |v| {
                        cfg.odata_password = v;
                    }
                }
                if (parseFactValue(sap_cfg.content, "odata_credential", "version")) |v| {
                    cfg.odata_version = if (std.mem.eql(u8, v, "4") or std.mem.eql(u8, v, "4.0") or std.ascii.eqlIgnoreCase(v, "v4")) .v4 else .v2;
                }
            }
        }

        return cfg;
    }

    fn getEnvStr(key: []const u8, default: []const u8) []const u8 {
        return std.posix.getenv(key) orelse default;
    }

    fn getEnvU16(key: []const u8, default: u16) u16 {
        const val = std.posix.getenv(key) orelse return default;
        return std.fmt.parseInt(u16, val, 10) catch default;
    }

    fn getEnvU32(key: []const u8, default: u32) u32 {
        const val = std.posix.getenv(key) orelse return default;
        return std.fmt.parseInt(u32, val, 10) catch default;
    }

    fn getEnvBool(key: []const u8, default: bool) bool {
        const val = std.posix.getenv(key) orelse return default;
        if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1")) return true;
        if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0")) return false;
        return default;
    }

    fn getEnvVersion(key: []const u8, default: ODataVersion) ODataVersion {
        const val = std.posix.getenv(key) orelse return default;
        if (std.mem.eql(u8, val, "4") or std.mem.eql(u8, val, "4.0") or std.mem.eql(u8, val, "v4")) return .v4;
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

const SapConfigFile = struct {
    path: []const u8,
    content: []const u8,
};

var sap_config_cache: ?SapConfigFile = null;

fn parseFactValue(content: []const u8, predicate: []const u8, key: []const u8) ?[]const u8 {
    var pattern_buf: [256]u8 = undefined;
    const prefix = std.fmt.bufPrint(&pattern_buf, "{s}(\"{s}\",", .{ predicate, key }) catch return null;

    const prefix_pos = mem.indexOf(u8, content, prefix) orelse return null;
    var i = prefix_pos + prefix.len;
    while (i < content.len and std.ascii.isWhitespace(content[i])) : (i += 1) {}
    if (i >= content.len or content[i] != '"') return null;

    const value_start = i + 1;
    const value_end = mem.indexOfScalarPos(u8, content, value_start, '"') orelse return null;
    return content[value_start..value_end];
}

fn getSapConfig(allocator: std.mem.Allocator) ?SapConfigFile {
    if (sap_config_cache) |cached| return cached;

    if (std.posix.getenv("SAP_CONFIG_PATH")) |path| {
        if (readPathAlloc(allocator, path) catch null) |content| {
            const cfg = SapConfigFile{ .path = path, .content = content };
            sap_config_cache = cfg;
            return cfg;
        }
    }

    const candidates = [_][]const u8{
        ".vscode/sap_config.local.mg",
        ".vscode/sap_config.mg",
        "../.vscode/sap_config.local.mg",
        "../.vscode/sap_config.mg",
        "../../.vscode/sap_config.local.mg",
        "../../.vscode/sap_config.mg",
        "../../../.vscode/sap_config.local.mg",
        "../../../.vscode/sap_config.mg",
        "../../../../.vscode/sap_config.local.mg",
        "../../../../.vscode/sap_config.mg",
        "../../../../../.vscode/sap_config.local.mg",
        "../../../../../.vscode/sap_config.mg",
        "../../../../../../.vscode/sap_config.local.mg",
        "../../../../../../.vscode/sap_config.mg",
        "/Users/user/Documents/nucleusai/.vscode/sap_config.local.mg",
        "/Users/user/Documents/nucleusai/.vscode/sap_config.mg",
    };

    for (candidates) |candidate| {
        if (readPathAlloc(allocator, candidate) catch null) |content| {
            const cfg = SapConfigFile{ .path = candidate, .content = content };
            sap_config_cache = cfg;
            return cfg;
        }
    }

    return null;
}

fn readPathAlloc(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (std.fs.path.isAbsolute(path)) {
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();
        return try file.readToEndAlloc(allocator, 2 * 1024 * 1024);
    }

    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    return try file.readToEndAlloc(allocator, 2 * 1024 * 1024);
}
