//! Service Router
//!
//! Resolves OpenAI API requests to backend services.
//! Extracts the model name from the request body, looks up the corresponding
//! backend service via compiled routing rules, and proxies the request.
//!
//! Mangle rules are defined in:
//!   - mangle/a2a/facts.mg    (service_registry, model_registry declarations)
//!   - mangle/a2a/rules.mg    (routable, resolve_service_for_intent rules)
//!   - mangle/domain/*.mg     (service-specific model definitions)

const std = @import("std");
const mem = std.mem;
const json = std.json;
const net = std.net;
const posix = std.posix;
const Allocator = mem.Allocator;
const http_client = @import("http_client.zig");

// ============================================================================
// Service Descriptor
// ============================================================================

pub const ServiceId = enum {
    local_models,
    deductive_db,
    gen_foundry,
    mesh_gateway,
    pipeline_svc,
    time_series,
    news_svc,
    search_svc,
    universal_prompt,

    pub fn displayName(self: ServiceId) []const u8 {
        return switch (self) {
            .local_models => "local-models",
            .deductive_db => "deductive-db",
            .gen_foundry => "gen-foundry",
            .mesh_gateway => "mesh-gateway",
            .pipeline_svc => "pipeline-svc",
            .time_series => "time-series",
            .news_svc => "news-svc",
            .search_svc => "search-svc",
            .universal_prompt => "universal-prompt",
        };
    }
};

pub const ServiceEntry = struct {
    id: ServiceId,
    base_url: []const u8,
    port: u16,
    healthy: bool = true,
};

pub const EndpointKind = enum {
    chat,
    completions,
    embeddings,
    models,
};

pub const RouteResult = struct {
    service: ServiceEntry,
    proxy_path: []const u8,
};

pub const ProxyResponse = http_client.Response;

// ============================================================================
// Model → Service mapping (compiled from service_routing.mg)
// ============================================================================

const ModelRoute = struct {
    model_prefix: []const u8,
    service_id: ServiceId,
};

// Static routing table derived from mangle/service_routing.mg.
// Sources: model_routing.mg, test_backend_rules.mg, t4_optimization.mg,
//          quantization_rules.mg, ainuc-be-po-deductive-db/zig/src/main.zig,
//          ainuc-be-po-gen-foundry/zig/src/main.zig.
// Prefix-match is used; more-specific prefixes come first.
const model_routes = [_]ModelRoute{
    // --- From ainuc-be-po-deductive-db ---
    .{ .model_prefix = "ainuc-deductive", .service_id = .deductive_db },
    .{ .model_prefix = "ainuc-mangle", .service_id = .deductive_db },
    // --- From ainuc-be-po-gen-foundry ---
    .{ .model_prefix = "ainuc-gen-foundry", .service_id = .gen_foundry },
    .{ .model_prefix = "ainuc-data-copilot", .service_id = .gen_foundry },
    // --- From model_routing.mg ---
    .{ .model_prefix = "phi3-lora", .service_id = .local_models },
    .{ .model_prefix = "llama3-8b", .service_id = .local_models },
    .{ .model_prefix = "llama3-70b", .service_id = .local_models },
    .{ .model_prefix = "codellama-7b", .service_id = .local_models },
    .{ .model_prefix = "codellama-13b", .service_id = .local_models },
    .{ .model_prefix = "mistral-7b", .service_id = .local_models },
    .{ .model_prefix = "qwen2-7b", .service_id = .local_models },
    // --- From test_backend_rules.mg (GGUF / safetensors) ---
    .{ .model_prefix = "LFM2.5-1.2B-Instruct-GGUF", .service_id = .local_models },
    .{ .model_prefix = "HY-MT1.5-7B", .service_id = .local_models },
    .{ .model_prefix = "deepseek-coder-33b-instruct", .service_id = .local_models },
    .{ .model_prefix = "Llama-3.3-70B-Instruct", .service_id = .local_models },
    .{ .model_prefix = "translategemma-27b-it-GGUF", .service_id = .local_models },
    .{ .model_prefix = "Kimi-K2.5-GGUF", .service_id = .local_models },
    .{ .model_prefix = "google-gemma-3-270m-it", .service_id = .local_models },
    .{ .model_prefix = "microsoft-phi-2", .service_id = .local_models },
    // --- From t4_optimization.mg ---
    .{ .model_prefix = "gemma-2b", .service_id = .local_models },
    .{ .model_prefix = "gemma-7b", .service_id = .local_models },
    .{ .model_prefix = "llama-7b", .service_id = .local_models },
    .{ .model_prefix = "llama-13b", .service_id = .local_models },
    .{ .model_prefix = "phi-2", .service_id = .local_models },
    .{ .model_prefix = "phi-3", .service_id = .local_models },
};

// ============================================================================
// Router
// ============================================================================

pub const Router = struct {
    allocator: Allocator,
    services: std.EnumArray(ServiceId, ServiceEntry),

    pub fn init(allocator: Allocator, cfg: ServiceConfig) Router {
        var services = std.EnumArray(ServiceId, ServiceEntry).initUndefined();

        services.set(.local_models, .{
            .id = .local_models,
            .base_url = cfg.local_models_url,
            .port = cfg.local_models_port,
        });
        services.set(.deductive_db, .{
            .id = .deductive_db,
            .base_url = cfg.deductive_db_url,
            .port = cfg.deductive_db_port,
        });
        services.set(.gen_foundry, .{
            .id = .gen_foundry,
            .base_url = cfg.gen_foundry_url,
            .port = cfg.gen_foundry_port,
        });
        services.set(.mesh_gateway, .{
            .id = .mesh_gateway,
            .base_url = cfg.mesh_gateway_url,
            .port = cfg.mesh_gateway_port,
        });
        services.set(.pipeline_svc, .{
            .id = .pipeline_svc,
            .base_url = cfg.pipeline_svc_url,
            .port = cfg.pipeline_svc_port,
        });
        services.set(.time_series, .{
            .id = .time_series,
            .base_url = cfg.time_series_url,
            .port = cfg.time_series_port,
        });
        services.set(.news_svc, .{
            .id = .news_svc,
            .base_url = cfg.news_svc_url,
            .port = cfg.news_svc_port,
        });
        services.set(.search_svc, .{
            .id = .search_svc,
            .base_url = cfg.search_svc_url,
            .port = cfg.search_svc_port,
        });
        services.set(.universal_prompt, .{
            .id = .universal_prompt,
            .base_url = cfg.universal_prompt_url,
            .port = cfg.universal_prompt_port,
        });

        return Router{
            .allocator = allocator,
            .services = services,
        };
    }

    // ------------------------------------------------------------------
    // Resolve model → backend
    // ------------------------------------------------------------------

    /// Extract the "model" field from an OpenAI-compatible JSON request body.
    pub fn extractModel(body: []const u8) ?[]const u8 {
        // Fast path: find "model":" in the body
        const needle = "\"model\"";
        const pos = mem.indexOf(u8, body, needle) orelse return null;
        const after_key = body[pos + needle.len ..];

        // Skip optional whitespace and colon
        var i: usize = 0;
        while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}
        if (i >= after_key.len) return null;

        // Expect opening quote
        if (after_key[i] != '"') return null;
        i += 1;
        const start = i;

        // Find closing quote
        while (i < after_key.len and after_key[i] != '"') : (i += 1) {}
        if (i >= after_key.len) return null;

        return after_key[start..i];
    }

    /// Resolve a model name to a ServiceId using the Mangle-derived routing table.
    pub fn resolveService(model: []const u8) ServiceId {
        for (&model_routes) |route_entry| {
            if (mem.startsWith(u8, model, route_entry.model_prefix)) {
                return route_entry.service_id;
            }
        }
        // Fallback: anything not matched is assumed to be a local Ollama model
        return .local_models;
    }

    /// Map an OpenAI endpoint kind to the proxy path for a given service.
    pub fn proxyPath(service_id: ServiceId, endpoint: EndpointKind) []const u8 {
        _ = service_id;
        return switch (endpoint) {
            .chat => "/v1/chat/completions",
            .completions => "/v1/completions",
            .embeddings => "/v1/embeddings",
            .models => "/v1/models",
        };
    }

    /// Full resolution: body → RouteResult
    pub fn route(self: *Router, body: []const u8, endpoint: EndpointKind) RouteResult {
        const model = extractModel(body) orelse "default";
        const sid = resolveService(model);
        const entry = self.services.get(sid);
        const path = proxyPath(sid, endpoint);

        std.log.info("route: model=\"{s}\" → service={s} ({s}:{d}{s})", .{
            model,
            sid.displayName(),
            entry.base_url,
            entry.port,
            path,
        });

        return RouteResult{
            .service = entry,
            .proxy_path = path,
        };
    }

    // ------------------------------------------------------------------
    // Proxy HTTP request to resolved backend
    // ------------------------------------------------------------------

    /// Proxy a POST request to the resolved backend and return the parsed response.
    pub fn proxyPost(self: *Router, target: RouteResult, body: []const u8) !ProxyResponse {
        const host = stripScheme(target.service.base_url);
        const port = target.service.port;

        const request = try http_client.buildJsonRequest(
            self.allocator,
            "POST",
            host,
            target.proxy_path,
            body,
            null,
        );
        defer self.allocator.free(request);

        return http_client.executeRequest(self.allocator, host, port, request);
    }

    /// Proxy a GET request to the resolved backend.
    pub fn proxyGet(self: *Router, target: RouteResult) !ProxyResponse {
        const host = stripScheme(target.service.base_url);
        const port = target.service.port;

        const request = try http_client.buildJsonRequest(
            self.allocator,
            "GET",
            host,
            target.proxy_path,
            null,
            null,
        );
        defer self.allocator.free(request);

        return http_client.executeRequest(self.allocator, host, port, request);
    }

    /// Proxy a POST request and stream the raw upstream HTTP response to the downstream client.
    pub fn proxyPostStream(self: *Router, target: RouteResult, body: []const u8, downstream: net.Stream) !void {
        const host = stripScheme(target.service.base_url);
        const port = target.service.port;
        const request = try http_client.buildJsonRequest(
            self.allocator,
            "POST",
            host,
            target.proxy_path,
            body,
            null,
        );
        defer self.allocator.free(request);

        try http_client.streamRequest(host, port, request, downstream);
    }

    /// Aggregate /v1/models from every healthy backend.
    pub fn aggregateModels(self: *Router) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        var w = result.writer(self.allocator);

        try w.writeAll("{\"object\":\"list\",\"data\":[");

        // Emit virtual model entries from the static routing table
        var first = true;
        for (&model_routes) |mr| {
            const entry = self.services.get(mr.service_id);
            if (!entry.healthy) continue;

            if (!first) try w.writeAll(",");
            try w.print(
                "{{\"id\":\"{s}\",\"object\":\"model\",\"created\":0,\"owned_by\":\"{s}\"}}",
                .{ mr.model_prefix, mr.service_id.displayName() },
            );
            first = false;
        }

        try w.writeAll("]}");

        return result.toOwnedSlice(self.allocator);
    }

    // ------------------------------------------------------------------
    // Health checking
    // ------------------------------------------------------------------

    /// Mark a service as unhealthy.
    pub fn markUnhealthy(self: *Router, sid: ServiceId) void {
        var entry = self.services.get(sid);
        entry.healthy = false;
        self.services.set(sid, entry);
        std.log.warn("service {s} marked unhealthy", .{sid.displayName()});
    }

    /// Mark a service as healthy.
    pub fn markHealthy(self: *Router, sid: ServiceId) void {
        var entry = self.services.get(sid);
        entry.healthy = true;
        self.services.set(sid, entry);
    }
};

// ============================================================================
// Configuration for all backend service URLs
// ============================================================================

pub const ServiceConfig = struct {
    local_models_url: []const u8 = "localhost",
    local_models_port: u16 = 11434,

    deductive_db_url: []const u8 = "localhost",
    deductive_db_port: u16 = 7474,

    gen_foundry_url: []const u8 = "localhost",
    gen_foundry_port: u16 = 8001,

    mesh_gateway_url: []const u8 = "localhost",
    mesh_gateway_port: u16 = 9881,

    pipeline_svc_url: []const u8 = "localhost",
    pipeline_svc_port: u16 = 8002,

    time_series_url: []const u8 = "localhost",
    time_series_port: u16 = 8003,

    news_svc_url: []const u8 = "localhost",
    news_svc_port: u16 = 9200,

    search_svc_url: []const u8 = "localhost",
    search_svc_port: u16 = 8004,

    universal_prompt_url: []const u8 = "localhost",
    universal_prompt_port: u16 = 8005,

    pub fn loadFromEnv() ServiceConfig {
        var cfg = ServiceConfig{};

        if (std.posix.getenv("SVC_LOCAL_MODELS_URL")) |v| cfg.local_models_url = v;
        if (std.posix.getenv("SVC_LOCAL_MODELS_PORT")) |v| cfg.local_models_port = std.fmt.parseInt(u16, v, 10) catch cfg.local_models_port;

        if (std.posix.getenv("SVC_DEDUCTIVE_DB_URL")) |v| cfg.deductive_db_url = v;
        if (std.posix.getenv("SVC_DEDUCTIVE_DB_PORT")) |v| cfg.deductive_db_port = std.fmt.parseInt(u16, v, 10) catch cfg.deductive_db_port;

        if (std.posix.getenv("SVC_GEN_FOUNDRY_URL")) |v| cfg.gen_foundry_url = v;
        if (std.posix.getenv("SVC_GEN_FOUNDRY_PORT")) |v| cfg.gen_foundry_port = std.fmt.parseInt(u16, v, 10) catch cfg.gen_foundry_port;

        if (std.posix.getenv("SVC_MESH_GATEWAY_URL")) |v| cfg.mesh_gateway_url = v;
        if (std.posix.getenv("SVC_MESH_GATEWAY_PORT")) |v| cfg.mesh_gateway_port = std.fmt.parseInt(u16, v, 10) catch cfg.mesh_gateway_port;

        if (std.posix.getenv("SVC_PIPELINE_SVC_URL")) |v| cfg.pipeline_svc_url = v;
        if (std.posix.getenv("SVC_PIPELINE_SVC_PORT")) |v| cfg.pipeline_svc_port = std.fmt.parseInt(u16, v, 10) catch cfg.pipeline_svc_port;

        if (std.posix.getenv("SVC_TIME_SERIES_URL")) |v| cfg.time_series_url = v;
        if (std.posix.getenv("SVC_TIME_SERIES_PORT")) |v| cfg.time_series_port = std.fmt.parseInt(u16, v, 10) catch cfg.time_series_port;

        if (std.posix.getenv("SVC_NEWS_SVC_URL")) |v| cfg.news_svc_url = v;
        if (std.posix.getenv("SVC_NEWS_SVC_PORT")) |v| cfg.news_svc_port = std.fmt.parseInt(u16, v, 10) catch cfg.news_svc_port;

        if (std.posix.getenv("SVC_SEARCH_SVC_URL")) |v| cfg.search_svc_url = v;
        if (std.posix.getenv("SVC_SEARCH_SVC_PORT")) |v| cfg.search_svc_port = std.fmt.parseInt(u16, v, 10) catch cfg.search_svc_port;

        if (std.posix.getenv("SVC_UNIVERSAL_PROMPT_URL")) |v| cfg.universal_prompt_url = v;
        if (std.posix.getenv("SVC_UNIVERSAL_PROMPT_PORT")) |v| cfg.universal_prompt_port = std.fmt.parseInt(u16, v, 10) catch cfg.universal_prompt_port;

        return cfg;
    }
};

// ============================================================================
// Helpers
// ============================================================================

fn stripScheme(url: []const u8) []const u8 {
    if (mem.startsWith(u8, url, "https://")) return url[8..];
    if (mem.startsWith(u8, url, "http://")) return url[7..];
    return url;
}

fn bindTestListener() !struct { listener: net.Server, port: u16 } {
    var port: u16 = 39080;
    while (port < 39180) : (port += 1) {
        const address = try net.Address.parseIp4("127.0.0.1", port);
        const listener = address.listen(.{
            .reuse_address = true,
        }) catch |err| switch (err) {
            error.AddressInUse => continue,
            else => return err,
        };
        return .{ .listener = listener, .port = port };
    }
    return error.NoAvailableTestPort;
}

const MockHttpServer = struct {
    listener: net.Server,
    response: []const u8,

    fn run(self: *MockHttpServer) void {
        const conn = self.listener.accept() catch return;
        defer conn.stream.close();

        var buf: [2048]u8 = undefined;
        _ = conn.stream.read(&buf) catch return;
        conn.stream.writeAll(self.response) catch return;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "extract model from body" {
    const body =
        \\{"model": "ainuc-deductive-v1", "messages": []}
    ;
    const model = Router.extractModel(body);
    try std.testing.expect(model != null);
    try std.testing.expectEqualStrings("ainuc-deductive-v1", model.?);
}

test "extract model compact json" {
    const body =
        \\{"model":"phi3-lora","messages":[]}
    ;
    const model = Router.extractModel(body);
    try std.testing.expect(model != null);
    try std.testing.expectEqualStrings("phi3-lora", model.?);
}

test "resolve service for deductive model" {
    const sid = Router.resolveService("ainuc-deductive-v1");
    try std.testing.expectEqual(ServiceId.deductive_db, sid);
}

test "resolve service for mangle model" {
    const sid = Router.resolveService("ainuc-mangle-v1");
    try std.testing.expectEqual(ServiceId.deductive_db, sid);
}

test "resolve service for model_routing.mg model" {
    try std.testing.expectEqual(ServiceId.local_models, Router.resolveService("phi3-lora"));
    try std.testing.expectEqual(ServiceId.local_models, Router.resolveService("llama3-8b"));
    try std.testing.expectEqual(ServiceId.local_models, Router.resolveService("codellama-7b"));
    try std.testing.expectEqual(ServiceId.local_models, Router.resolveService("mistral-7b"));
    try std.testing.expectEqual(ServiceId.local_models, Router.resolveService("qwen2-7b"));
}

test "resolve service for GGUF model" {
    try std.testing.expectEqual(ServiceId.local_models, Router.resolveService("LFM2.5-1.2B-Instruct-GGUF"));
    try std.testing.expectEqual(ServiceId.local_models, Router.resolveService("Kimi-K2.5-GGUF"));
}

test "resolve service for t4 model" {
    try std.testing.expectEqual(ServiceId.local_models, Router.resolveService("gemma-2b"));
    try std.testing.expectEqual(ServiceId.local_models, Router.resolveService("phi-3"));
}

test "resolve unknown model falls back to local_models" {
    const sid = Router.resolveService("totally-unknown-model");
    try std.testing.expectEqual(ServiceId.local_models, sid);
}

test "proxy path for chat endpoint" {
    const path = Router.proxyPath(.deductive_db, .chat);
    try std.testing.expectEqualStrings("/v1/chat/completions", path);
}

test "strip scheme" {
    try std.testing.expectEqualStrings("localhost", stripScheme("http://localhost"));
    try std.testing.expectEqualStrings("example.com", stripScheme("https://example.com"));
    try std.testing.expectEqualStrings("raw-host", stripScheme("raw-host"));
}

test "proxyPost preserves upstream status and body" {
    const raw_response =
        "HTTP/1.1 503 Service Unavailable\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 27\r\n\r\n" ++
        "{\"error\":\"upstream-unready\"}";

    const bound = try bindTestListener();
    var server = MockHttpServer{
        .listener = bound.listener,
        .response = raw_response,
    };
    const thread = try std.Thread.spawn(.{}, MockHttpServer.run, .{&server});
    defer {
        server.listener.deinit();
        thread.join();
    }

    var router = Router.init(std.testing.allocator, .{
        .local_models_url = "127.0.0.1",
        .local_models_port = bound.port,
    });
    const target = RouteResult{
        .service = router.services.get(.local_models),
        .proxy_path = "/v1/chat/completions",
    };

    var response = try router.proxyPost(target, "{\"model\":\"test\"}");
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 503), response.status);
    try std.testing.expectEqualStrings("{\"error\":\"upstream-unready\"}", response.body);
}
