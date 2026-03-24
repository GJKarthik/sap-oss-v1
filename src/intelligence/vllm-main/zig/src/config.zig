//! Configuration Module
//!
//! Handles environment variables and configuration for the local models proxy.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Config = struct {
    // Server settings
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,

    // Metrics binding (127.0.0.1 in production; 0.0.0.0 only for local dev)
    metrics_bind: []const u8 = "127.0.0.1",

    // API settings
    api_key: ?[]const u8 = null,

    // Model defaults
    default_model: ?[]const u8 = null,
    default_temperature: f32 = 0.7,
    default_max_tokens: u32 = 2048,

    // Performance settings
    max_connections: u32 = 1024,
    request_timeout_ms: u32 = 300000,
    streaming_buffer_size: u32 = 8192,

    // Features
    streaming_enabled: bool = true,
    mangle_enabled: bool = true,
    mangle_rules_path: ?[]const u8 = null,
    cors_enabled: bool = true,
    toon_enabled: bool = true,
    use_local_llama: bool = true,

    // TRT engine settings (optional — GGUF path only if TRT engine file exists)
    trt_engine_path: ?[]const u8 = null,   // e.g. /models/qwen35-9b-awq.engine
    trt_max_inflight: i32 = 64,            // max concurrent TRT requests
    trt_quant_mode: i32 = 2,              // 0=FP16, 1=INT8, 2=AWQ

    // Rate limiting (configurable per deployment)
    rate_limit_rps: u32 = 1000,           // requests per second
    rate_limit_burst: u32 = 1000,          // burst capacity

    // Logging
    log_level: LogLevel = .info,
    log_requests: bool = false,

    // Deductive DB settings (for metrics/logs replication)
    deductive_db_url: []const u8 = "http://deductive-db:7474",
    deductive_db_database: []const u8 = "neo4j",
    deductive_db_username: ?[]const u8 = null,
    deductive_db_password: ?[]const u8 = null,
    deductive_db_enabled: bool = true,
    metrics_buffer_size: u32 = 100,
    metrics_retention_days: u32 = 30,
    log_retention_days: u32 = 7,

    // Service routing (OpenAI gateway proxy targets)
    svc_local_models_url: []const u8 = "localhost",
    svc_local_models_port: u16 = 11434,
    svc_deductive_db_url: []const u8 = "localhost",
    svc_deductive_db_port: u16 = 7474,
    svc_gen_foundry_url: []const u8 = "localhost",
    svc_gen_foundry_port: u16 = 8001,
    svc_mesh_gateway_url: []const u8 = "localhost",
    svc_mesh_gateway_port: u16 = 9881,
    svc_pipeline_svc_url: []const u8 = "localhost",
    svc_pipeline_svc_port: u16 = 8002,
    svc_time_series_url: []const u8 = "localhost",
    svc_time_series_port: u16 = 8003,
    svc_news_svc_url: []const u8 = "localhost",
    svc_news_svc_port: u16 = 9200,
    svc_search_svc_url: []const u8 = "localhost",
    svc_search_svc_port: u16 = 8004,
    svc_universal_prompt_url: []const u8 = "localhost",
    svc_universal_prompt_port: u16 = 8005,

    pub fn loadFromEnv() Config {
        var cfg = Config{};

        // --- Server ---
        cfg.host = envStr("HOST", cfg.host);
        cfg.port = envInt(u16, "PORT", cfg.port);

        // --- Metrics bind address ---
        cfg.metrics_bind = envStr("METRICS_BIND", cfg.metrics_bind);

        // --- API / Model ---
        cfg.api_key = std.posix.getenv("API_KEY") orelse cfg.api_key;
        cfg.default_model = std.posix.getenv("DEFAULT_MODEL") orelse cfg.default_model;
        if (std.posix.getenv("DEFAULT_TEMPERATURE")) |v| {
            cfg.default_temperature = std.fmt.parseFloat(f32, v) catch cfg.default_temperature;
        }
        cfg.default_max_tokens = envInt(u32, "DEFAULT_MAX_TOKENS", cfg.default_max_tokens);

        // --- Performance ---
        cfg.max_connections = envInt(u32, "MAX_CONNECTIONS", cfg.max_connections);
        cfg.request_timeout_ms = envInt(u32, "REQUEST_TIMEOUT_MS", cfg.request_timeout_ms);

        // --- Feature flags ---
        cfg.streaming_enabled = envBool("STREAMING_ENABLED", cfg.streaming_enabled);
        cfg.mangle_enabled = envBool("MANGLE_ENABLED", cfg.mangle_enabled);
        cfg.mangle_rules_path = std.posix.getenv("MANGLE_RULES_PATH") orelse cfg.mangle_rules_path;
        cfg.cors_enabled = envBool("CORS_ENABLED", cfg.cors_enabled);
        cfg.toon_enabled = envBool("TOON_ENABLED", cfg.toon_enabled);
        cfg.use_local_llama = envBool("USE_LOCAL_LLAMA", cfg.use_local_llama);

        // --- TRT engine ---
        cfg.trt_engine_path = std.posix.getenv("TRT_ENGINE_PATH") orelse cfg.trt_engine_path;
        cfg.trt_max_inflight = envInt(i32, "TRT_MAX_INFLIGHT", cfg.trt_max_inflight);
        cfg.trt_quant_mode = envInt(i32, "TRT_QUANT_MODE", cfg.trt_quant_mode);

        // --- Rate limiting ---
        cfg.rate_limit_rps = envInt(u32, "RATE_LIMIT_RPS", cfg.rate_limit_rps);
        cfg.rate_limit_burst = envInt(u32, "RATE_LIMIT_BURST", cfg.rate_limit_burst);

        // --- Logging ---
        if (std.posix.getenv("LOG_LEVEL")) |v| cfg.log_level = parseLogLevel(v);
        cfg.log_requests = envBool("LOG_REQUESTS", cfg.log_requests);

        // --- Deductive DB ---
        cfg.deductive_db_url = envStr("DEDUCTIVE_DB_URL", cfg.deductive_db_url);
        cfg.deductive_db_database = envStr("DEDUCTIVE_DB_DATABASE", cfg.deductive_db_database);
        cfg.deductive_db_username = std.posix.getenv("DEDUCTIVE_DB_USERNAME") orelse cfg.deductive_db_username;
        cfg.deductive_db_password = std.posix.getenv("DEDUCTIVE_DB_PASSWORD") orelse cfg.deductive_db_password;
        cfg.deductive_db_enabled = envBool("DEDUCTIVE_DB_ENABLED", cfg.deductive_db_enabled);
        cfg.metrics_buffer_size = envInt(u32, "METRICS_BUFFER_SIZE", cfg.metrics_buffer_size);
        cfg.metrics_retention_days = envInt(u32, "METRICS_RETENTION_DAYS", cfg.metrics_retention_days);
        cfg.log_retention_days = envInt(u32, "LOG_RETENTION_DAYS", cfg.log_retention_days);

        // --- Service routing ---
        inline for (.{
            .{ "SVC_LOCAL_MODELS", &cfg.svc_local_models_url, &cfg.svc_local_models_port },
            .{ "SVC_DEDUCTIVE_DB", &cfg.svc_deductive_db_url, &cfg.svc_deductive_db_port },
            .{ "SVC_GEN_FOUNDRY", &cfg.svc_gen_foundry_url, &cfg.svc_gen_foundry_port },
            .{ "SVC_MESH_GATEWAY", &cfg.svc_mesh_gateway_url, &cfg.svc_mesh_gateway_port },
            .{ "SVC_PIPELINE_SVC", &cfg.svc_pipeline_svc_url, &cfg.svc_pipeline_svc_port },
            .{ "SVC_TIME_SERIES", &cfg.svc_time_series_url, &cfg.svc_time_series_port },
            .{ "SVC_NEWS_SVC", &cfg.svc_news_svc_url, &cfg.svc_news_svc_port },
            .{ "SVC_SEARCH_SVC", &cfg.svc_search_svc_url, &cfg.svc_search_svc_port },
            .{ "SVC_UNIVERSAL_PROMPT", &cfg.svc_universal_prompt_url, &cfg.svc_universal_prompt_port },
        }) |svc| {
            svc[1].* = envStr(svc[0] ++ "_URL", svc[1].*);
            svc[2].* = envInt(u16, svc[0] ++ "_PORT", svc[2].*);
        }

        return cfg;
    }
};

// ---------------------------------------------------------------------------
// Env helpers — reduce repetition in loadFromEnv()
// ---------------------------------------------------------------------------

fn envStr(key: [:0]const u8, fallback: []const u8) []const u8 {
    return std.posix.getenv(key) orelse fallback;
}

fn envInt(comptime T: type, key: [:0]const u8, fallback: T) T {
    const v = std.posix.getenv(key) orelse return fallback;
    return std.fmt.parseInt(T, v, 10) catch fallback;
}

fn envBool(key: [:0]const u8, fallback: bool) bool {
    const v = std.posix.getenv(key) orelse return fallback;
    return std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
}

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,
};

fn parseLogLevel(s: []const u8) LogLevel {
    if (std.mem.eql(u8, s, "debug")) return .debug;
    if (std.mem.eql(u8, s, "info")) return .info;
    if (std.mem.eql(u8, s, "warn")) return .warn;
    if (std.mem.eql(u8, s, "error")) return .err;
    return .info;
}

// ============================================================================
// Tests
// ============================================================================

test "default config" {
    const cfg = Config{};
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.host);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.metrics_bind);
    try std.testing.expectEqual(true, cfg.streaming_enabled);
    try std.testing.expectEqual(true, cfg.toon_enabled);
    try std.testing.expectEqual(true, cfg.use_local_llama);
}

test "log level parsing" {
    try std.testing.expectEqual(LogLevel.debug, parseLogLevel("debug"));
    try std.testing.expectEqual(LogLevel.info, parseLogLevel("info"));
    try std.testing.expectEqual(LogLevel.warn, parseLogLevel("warn"));
    try std.testing.expectEqual(LogLevel.err, parseLogLevel("error"));
    try std.testing.expectEqual(LogLevel.info, parseLogLevel("unknown"));
}
