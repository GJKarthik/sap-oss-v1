//! BDC AIPrompt Streaming - Main Entry Point
//! Full AIPrompt protocol implementation with SAP HANA storage
//! GPU-Accelerated for high-throughput message processing

const std = @import("std");
const types = @import("connector_types");
const broker = @import("broker");

// GPU Infrastructure (SAP NIM pattern)
const gpu_context = @import("gpu/context.zig");
const gpu_backend = @import("gpu/backend.zig");
const async_pipeline = @import("gpu/async_pipeline.zig");

// HTTP Server for OpenAI-compliant endpoints
const http_server = @import("http/server.zig");
const http_auth = @import("http/auth.zig");

const log = std.log.scoped(.aiprompt_main);

var global_broker: ?*broker.Broker = null;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config") or std.mem.eql(u8, args[i], "-c")) {
            i += 1;
            if (i < args.len) {
                config_path = args[i];
            }
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, args[i], "--version") or std.mem.eql(u8, args[i], "-v")) {
            printVersion();
            return;
        }
    }

    // Load configuration
    const config = try loadConfig(allocator, config_path);

    log.info("Starting BDC AIPrompt Streaming Broker", .{});
    log.info("Version: 1.0.0", .{});
    log.info("Protocol Version: 21", .{});
    log.info("Cluster: {s}", .{config.cluster_name});

    // Initialize and start broker with loaded config
    var broker_instance = try broker.Broker.init(allocator, .{
        .cluster_name = config.cluster_name,
        .broker_service_port = config.broker_service_port,
        .web_service_port = config.web_service_port,
        .num_io_threads = config.num_io_threads,
        .num_http_threads = config.num_http_threads,
        .max_message_size = config.max_message_size,
        .authentication_enabled = config.authentication_enabled,
        .authorization_enabled = config.authorization_enabled,
        .hana_host = config.hana_host,
        .hana_port = config.hana_port,
        .hana_schema = config.hana_schema,
    });
    defer broker_instance.deinit();
    global_broker = broker_instance;

    // Register signal handlers
    try setupSignalHandlers();

    // Start the broker
    try broker_instance.start();

    log.info("Broker started successfully", .{});
    log.info("Binary protocol listening on port {}", .{config.broker_service_port});
    log.info("HTTP admin API listening on port {}", .{config.web_service_port});

    // Wait for shutdown signal
    broker_instance.waitForShutdown();

    log.info("Broker shutdown complete", .{});
}

// ============================================================================
// Configuration Loading
// ============================================================================

const BrokerConfig = struct {
    // Cluster settings
    cluster_name: []const u8 = "standalone",

    // Network settings
    broker_service_port: u16 = 6650,
    broker_service_port_tls: u16 = 6651,
    web_service_port: u16 = 8080,
    web_service_port_tls: u16 = 8443,

    // Performance settings
    num_io_threads: u32 = 8,
    num_http_threads: u32 = 8,
    max_message_size: u64 = 5 * 1024 * 1024, // 5MB

    // Security settings
    authentication_enabled: bool = false,
    authorization_enabled: bool = false,
    tls_enabled: bool = false,

    // HANA storage settings
    hana_host: []const u8 = "",
    hana_port: u16 = 443,
    hana_schema: []const u8 = "AIPROMPT_STORAGE",

    // Retention settings
    default_retention_minutes: i64 = 0,
    default_retention_size_mb: i64 = 0,

    // Metrics settings
    metrics_enabled: bool = true,
    otel_endpoint: []const u8 = "",

    pub fn default() BrokerConfig {
        return .{};
    }
};

fn loadConfig(allocator: std.mem.Allocator, config_path: ?[]const u8) !BrokerConfig {
    // First, load defaults
    var config = BrokerConfig.default();

    // Override with environment variables
    config = loadFromEnv(config);

    // Override with config file if provided
    if (config_path) |path| {
        log.info("Loading configuration from: {s}", .{path});
        config = try loadFromFile(allocator, path, config);
    } else {
        // Try default config paths
        const default_paths = [_][]const u8{
            "/opt/aiprompt/conf/broker.conf",
            "/etc/aiprompt/broker.conf",
            "conf/broker.conf",
            "broker.conf",
        };

        for (default_paths) |path| {
            if (std.fs.cwd().access(path, .{})) |_| {
                log.info("Found configuration at: {s}", .{path});
                config = try loadFromFile(allocator, path, config);
                break;
            } else |_| {
                // File not found, try next
            }
        }
    }

    // Validate configuration
    try validateConfig(&config);

    log.info("Configuration loaded successfully", .{});
    return config;
}

fn loadFromEnv(config: BrokerConfig) BrokerConfig {
    var result = config;

    // Cluster settings
    if (std.posix.getenv("AIPROMPT_CLUSTER_NAME")) |val| {
        result.cluster_name = val;
    }

    // Network settings
    if (std.posix.getenv("AIPROMPT_BROKER_PORT")) |val| {
        result.broker_service_port = std.fmt.parseInt(u16, val, 10) catch result.broker_service_port;
    }
    if (std.posix.getenv("AIPROMPT_WEB_PORT")) |val| {
        result.web_service_port = std.fmt.parseInt(u16, val, 10) catch result.web_service_port;
    }

    // Performance settings
    if (std.posix.getenv("AIPROMPT_IO_THREADS")) |val| {
        result.num_io_threads = std.fmt.parseInt(u32, val, 10) catch result.num_io_threads;
    }
    if (std.posix.getenv("AIPROMPT_HTTP_THREADS")) |val| {
        result.num_http_threads = std.fmt.parseInt(u32, val, 10) catch result.num_http_threads;
    }
    if (std.posix.getenv("AIPROMPT_MAX_MESSAGE_SIZE")) |val| {
        result.max_message_size = std.fmt.parseInt(u64, val, 10) catch result.max_message_size;
    }

    // Security settings
    if (std.posix.getenv("AIPROMPT_AUTH_ENABLED")) |val| {
        result.authentication_enabled = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
    }
    if (std.posix.getenv("AIPROMPT_AUTHZ_ENABLED")) |val| {
        result.authorization_enabled = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
    }
    if (std.posix.getenv("AIPROMPT_TLS_ENABLED")) |val| {
        result.tls_enabled = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
    }

    // HANA settings
    if (std.posix.getenv("HANA_HOST")) |val| {
        result.hana_host = val;
    }
    if (std.posix.getenv("HANA_PORT")) |val| {
        result.hana_port = std.fmt.parseInt(u16, val, 10) catch result.hana_port;
    }
    if (std.posix.getenv("HANA_SCHEMA")) |val| {
        result.hana_schema = val;
    }

    // Metrics settings
    if (std.posix.getenv("AIPROMPT_METRICS_ENABLED")) |val| {
        result.metrics_enabled = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
    }
    if (std.posix.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")) |val| {
        result.otel_endpoint = val;
    }

    return result;
}

fn loadFromFile(allocator: std.mem.Allocator, path: []const u8, base_config: BrokerConfig) !BrokerConfig {
    var config = base_config;

    // Open and read the config file
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        log.err("Failed to open config file {s}: {}", .{ path, err });
        return error.ConfigFileNotFound;
    };
    defer file.close();

    // Get file size
    const stat = try file.stat();
    if (stat.size > 1024 * 1024) { // Max 1MB config file
        log.err("Config file too large: {} bytes", .{stat.size});
        return error.ConfigFileTooLarge;
    }

    // Read entire file
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Parse line by line (Java properties format: key=value)
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 0;

    while (lines.next()) |line| {
        line_num += 1;

        // Skip empty lines and comments
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Parse key=value
        const eq_idx = std.mem.indexOf(u8, trimmed, "=") orelse {
            log.warn("Invalid config line {}: missing '='", .{line_num});
            continue;
        };

        const key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
        const value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");

        // Map configuration keys to struct fields
        if (std.mem.eql(u8, key, "clusterName")) {
            config.cluster_name = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "brokerServicePort")) {
            config.broker_service_port = std.fmt.parseInt(u16, value, 10) catch {
                log.warn("Invalid brokerServicePort value: {s}", .{value});
                continue;
            };
        } else if (std.mem.eql(u8, key, "brokerServicePortTls")) {
            config.broker_service_port_tls = std.fmt.parseInt(u16, value, 10) catch {
                log.warn("Invalid brokerServicePortTls value: {s}", .{value});
                continue;
            };
        } else if (std.mem.eql(u8, key, "webServicePort")) {
            config.web_service_port = std.fmt.parseInt(u16, value, 10) catch {
                log.warn("Invalid webServicePort value: {s}", .{value});
                continue;
            };
        } else if (std.mem.eql(u8, key, "webServicePortTls")) {
            config.web_service_port_tls = std.fmt.parseInt(u16, value, 10) catch {
                log.warn("Invalid webServicePortTls value: {s}", .{value});
                continue;
            };
        } else if (std.mem.eql(u8, key, "numIOThreads")) {
            config.num_io_threads = std.fmt.parseInt(u32, value, 10) catch {
                log.warn("Invalid numIOThreads value: {s}", .{value});
                continue;
            };
        } else if (std.mem.eql(u8, key, "numHttpServerThreads")) {
            config.num_http_threads = std.fmt.parseInt(u32, value, 10) catch {
                log.warn("Invalid numHttpServerThreads value: {s}", .{value});
                continue;
            };
        } else if (std.mem.eql(u8, key, "maxMessageSize")) {
            config.max_message_size = std.fmt.parseInt(u64, value, 10) catch {
                log.warn("Invalid maxMessageSize value: {s}", .{value});
                continue;
            };
        } else if (std.mem.eql(u8, key, "authenticationEnabled")) {
            config.authentication_enabled = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "authorizationEnabled")) {
            config.authorization_enabled = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "tlsEnabled")) {
            config.tls_enabled = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "hanaHost")) {
            config.hana_host = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "hanaPort")) {
            config.hana_port = std.fmt.parseInt(u16, value, 10) catch {
                log.warn("Invalid hanaPort value: {s}", .{value});
                continue;
            };
        } else if (std.mem.eql(u8, key, "hanaSchema")) {
            config.hana_schema = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "defaultRetentionTimeInMinutes")) {
            config.default_retention_minutes = std.fmt.parseInt(i64, value, 10) catch {
                log.warn("Invalid defaultRetentionTimeInMinutes value: {s}", .{value});
                continue;
            };
        } else if (std.mem.eql(u8, key, "defaultRetentionSizeInMB")) {
            config.default_retention_size_mb = std.fmt.parseInt(i64, value, 10) catch {
                log.warn("Invalid defaultRetentionSizeInMB value: {s}", .{value});
                continue;
            };
        } else if (std.mem.eql(u8, key, "metricsEnabled")) {
            config.metrics_enabled = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "otelExporterEndpoint")) {
            config.otel_endpoint = try allocator.dupe(u8, value);
        } else {
            log.debug("Unknown config key: {s}", .{key});
        }
    }

    return config;
}

fn validateConfig(config: *const BrokerConfig) !void {
    // Validate port ranges
    if (config.broker_service_port == 0) {
        log.err("brokerServicePort cannot be 0", .{});
        return error.InvalidConfiguration;
    }
    if (config.web_service_port == 0) {
        log.err("webServicePort cannot be 0", .{});
        return error.InvalidConfiguration;
    }

    // Validate thread counts
    if (config.num_io_threads == 0) {
        log.err("numIOThreads must be at least 1", .{});
        return error.InvalidConfiguration;
    }
    if (config.num_http_threads == 0) {
        log.err("numHttpServerThreads must be at least 1", .{});
        return error.InvalidConfiguration;
    }

    // Validate message size
    if (config.max_message_size == 0) {
        log.err("maxMessageSize must be greater than 0", .{});
        return error.InvalidConfiguration;
    }
    if (config.max_message_size > 100 * 1024 * 1024) { // Max 100MB
        log.warn("maxMessageSize is very large: {} bytes", .{config.max_message_size});
    }

    // Warn if authentication/authorization mismatch
    if (config.authorization_enabled and !config.authentication_enabled) {
        log.warn("Authorization is enabled but authentication is disabled - authorization will be ineffective", .{});
    }

    // Validate HANA configuration if host is provided
    if (config.hana_host.len > 0) {
        if (config.hana_schema.len == 0) {
            log.err("hanaSchema must be specified when hanaHost is set", .{});
            return error.InvalidConfiguration;
        }
    }

    log.debug("Configuration validation passed", .{});
}

fn setupSignalHandlers() !void {
    // Register SIGINT and SIGTERM handlers for graceful shutdown
    const handler = struct {
        fn handle(sig: i32) callconv(.c) void {
            log.info("Received signal {}, initiating shutdown...", .{sig});
            if (global_broker) |b| {
                b.shutdown();
            }
        }
    };

    // Note: Signal handling implementation varies by platform
    // On POSIX systems:
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = handler.handle },
        .mask = 0, // Empty signal mask
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    log.debug("Signal handlers registered", .{});
}

fn printUsage() void {
    const usage =
        \\BDC AIPrompt Streaming Broker
        \\
        \\Usage: aiprompt-broker [OPTIONS]
        \\
        \\Options:
        \\  -c, --config <FILE>    Path to configuration file
        \\  -h, --help             Show this help message
        \\  -v, --version          Show version information
        \\
        \\Examples:
        \\  aiprompt-broker --config /opt/aiprompt/conf/broker.conf
        \\  aiprompt-broker -c broker.conf
        \\
        \\Environment Variables:
        \\  AIPROMPT_CLUSTER_NAME    Cluster name (default: standalone)
        \\  AIPROMPT_BROKER_PORT     Binary protocol port (default: 6650)
        \\  AIPROMPT_WEB_PORT        HTTP admin port (default: 8080)
        \\  AIPROMPT_IO_THREADS      Number of IO threads (default: 8)
        \\  AIPROMPT_HTTP_THREADS    Number of HTTP threads (default: 8)
        \\  AIPROMPT_AUTH_ENABLED    Enable authentication (true/false)
        \\  AIPROMPT_TLS_ENABLED     Enable TLS (true/false)
        \\  HANA_HOST                SAP HANA host
        \\  HANA_PORT                SAP HANA port (default: 443)
        \\  HANA_SCHEMA              SAP HANA schema name
        \\  HANA_USER                SAP HANA username
        \\  HANA_PASSWORD            SAP HANA password
        \\  HANA_PASSWORD_FILE       Path to HANA password file (more secure)
        \\
        \\Configuration File Format (Java properties):
        \\  # Comment
        \\  clusterName=standalone
        \\  brokerServicePort=6650
        \\  webServicePort=8080
        \\  hanaHost=your-hana.hanacloud.ondemand.com
        \\  hanaSchema=AIPROMPT_STORAGE
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn printVersion() void {
    const version =
        \\BDC AIPrompt Streaming
        \\Version: 1.0.0
        \\Protocol Version: 21
        \\Storage Backend: SAP HANA
        \\Build: Zig 0.13.0
        \\
        \\Copyright (c) 2024-2026 SAP SE
        \\License: Apache-2.0
        \\
    ;
    std.debug.print("{s}", .{version});
}