const std = @import("std");
const entities = @import("../domain/entities.zig");

pub const ConnectorError = error{
    OutOfMemory,
    InvalidParamsJson,
    ParamsMustBeObject,
    InvalidResponse,
    InvalidEndpointUrl,
    HttpRequestFailed,
    NonSuccessStatus,
    MissingMaxTokens,
    InvalidMaxTokens,
    MissingModel,
    MissingModelEndpoint,
    MissingAwsCredentials,
    MissingRequiredParameters,
    EmptyPrompt,
    MissingEndpoint,
    NotImplemented,
};

const anthropic_required_params = [_][]const u8{
    "model",
    "max_tokens",
    "messages",
};

const default_openai_chat_url = "https://api.openai.com/v1/chat/completions";
const default_anthropic_messages_url = "https://api.anthropic.com/v1/messages";
const default_anthropic_version = "2023-06-01";
const default_bedrock_region = "us-east-1";
const default_sagemaker_region = "ap-southeast-1";

pub const OpenAIAdapter = struct {
    pub fn buildRequestJson(
        allocator: std.mem.Allocator,
        connector: *const entities.ConnectorEntity,
        prompt: []const u8,
    ) ConnectorError![]u8 {
        var parsed = try parseParamsObject(allocator, connector.params_json);
        defer parsed.deinit();
        const arena = parsed.arena.allocator();

        const connector_prompt = try buildConnectorPrompt(arena, connector, prompt);
        var messages = std.json.Array.init(arena);
        if (connector.system_prompt.len > 0) {
            try messages.append(try makeRoleContentMessage(arena, "system", connector.system_prompt));
        }
        try messages.append(try makeRoleContentMessage(arena, "user", connector_prompt));

        var object = &parsed.value.object;
        try object.put("model", .{ .string = connector.model });
        try object.put("messages", .{ .array = messages });

        return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    }

    pub fn extractResponseText(
        allocator: std.mem.Allocator,
        response_json: []const u8,
    ) ConnectorError![]u8 {
        return try extractChoicesMessageContent(allocator, response_json);
    }

    pub fn invoke(
        allocator: std.mem.Allocator,
        connector: *const entities.ConnectorEntity,
        prompt: []const u8,
    ) ConnectorError![]u8 {
        const request_json = try buildRequestJson(allocator, connector, prompt);
        defer allocator.free(request_json);

        const endpoint = resolveEndpoint(default_openai_chat_url, connector.model_endpoint);

        var headers = std.ArrayListUnmanaged(std.http.Header){};
        defer headers.deinit(allocator);
        try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
        try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });

        const api_key = envOrEmpty("OPENAI_API_KEY");
        const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
        defer allocator.free(auth);
        try headers.append(allocator, .{ .name = "Authorization", .value = auth });

        const response_json = try postJson(allocator, endpoint, headers.items, request_json);
        defer allocator.free(response_json);

        return extractResponseText(allocator, response_json);
    }
};

pub const AnthropicAdapter = struct {
    pub fn validateConfiguration(
        allocator: std.mem.Allocator,
        connector: *const entities.ConnectorEntity,
    ) ConnectorError!void {
        if (connector.model.len == 0) return ConnectorError.MissingModel;

        var parsed = try parseParamsObject(allocator, connector.params_json);
        defer parsed.deinit();

        const max_tokens_value = parsed.value.object.get("max_tokens") orelse {
            return ConnectorError.MissingMaxTokens;
        };
        const max_tokens = switch (max_tokens_value) {
            .integer => |v| v,
            else => return ConnectorError.InvalidMaxTokens,
        };
        if (max_tokens < 1) return ConnectorError.InvalidMaxTokens;
    }

    pub fn buildRequestJson(
        allocator: std.mem.Allocator,
        connector: *const entities.ConnectorEntity,
        prompt: []const u8,
    ) ConnectorError![]u8 {
        var parsed = try parseParamsObject(allocator, connector.params_json);
        defer parsed.deinit();
        const arena = parsed.arena.allocator();

        const connector_prompt = try buildConnectorPrompt(arena, connector, prompt);
        var messages = std.json.Array.init(arena);
        try messages.append(try makeRoleContentMessage(arena, "user", connector_prompt));

        var object = &parsed.value.object;
        try object.put("model", .{ .string = connector.model });
        try object.put("system", .{ .string = connector.system_prompt });
        try object.put("messages", .{ .array = messages });

        if (!hasRequiredKeys(object.*, &anthropic_required_params)) {
            return ConnectorError.MissingRequiredParameters;
        }

        return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    }

    pub fn extractResponseText(
        allocator: std.mem.Allocator,
        response_json: []const u8,
    ) ConnectorError![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_json, .{}) catch {
            return ConnectorError.InvalidResponse;
        };
        defer parsed.deinit();

        if (parsed.value != .object) return ConnectorError.InvalidResponse;
        const content_value = parsed.value.object.get("content") orelse return ConnectorError.InvalidResponse;
        if (content_value != .array or content_value.array.items.len < 1) return ConnectorError.InvalidResponse;
        const first = content_value.array.items[0];
        if (first != .object) return ConnectorError.InvalidResponse;
        const text_value = first.object.get("text") orelse return ConnectorError.InvalidResponse;
        if (text_value != .string) return ConnectorError.InvalidResponse;
        return allocator.dupe(u8, text_value.string);
    }

    pub fn invoke(
        allocator: std.mem.Allocator,
        connector: *const entities.ConnectorEntity,
        prompt: []const u8,
    ) ConnectorError![]u8 {
        try validateConfiguration(allocator, connector);

        const request_json = try buildRequestJson(allocator, connector, prompt);
        defer allocator.free(request_json);

        const endpoint = resolveEndpoint(default_anthropic_messages_url, connector.model_endpoint);

        const version = try anthropicVersionFromParams(allocator, connector.params_json);
        defer allocator.free(version);

        var headers = std.ArrayListUnmanaged(std.http.Header){};
        defer headers.deinit(allocator);
        try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
        try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });
        try headers.append(allocator, .{ .name = "anthropic-version", .value = version });
        try headers.append(allocator, .{ .name = "x-api-key", .value = envOrEmpty("ANTHROPIC_API_KEY") });

        const response_json = try postJson(allocator, endpoint, headers.items, request_json);
        defer allocator.free(response_json);

        return extractResponseText(allocator, response_json);
    }
};

pub const AWSBedrockAdapter = struct {
    pub fn buildRequestJson(
        allocator: std.mem.Allocator,
        connector: *const entities.ConnectorEntity,
        prompt: []const u8,
    ) ConnectorError![]u8 {
        var parsed = try parseParamsObject(allocator, connector.params_json);
        defer parsed.deinit();
        const arena = parsed.arena.allocator();

        const connector_prompt = try buildConnectorPrompt(arena, connector, prompt);
        var request_object = std.json.ObjectMap.init(arena);
        try request_object.put("modelId", .{ .string = connector.model });

        var content_object = std.json.ObjectMap.init(arena);
        try content_object.put("text", .{ .string = connector_prompt });
        var content = std.json.Array.init(arena);
        try content.append(.{ .object = content_object });

        var message_object = std.json.ObjectMap.init(arena);
        try message_object.put("role", .{ .string = "user" });
        try message_object.put("content", .{ .array = content });

        var messages = std.json.Array.init(arena);
        try messages.append(.{ .object = message_object });
        try request_object.put("messages", .{ .array = messages });

        if (parsed.value.object.get("inferenceConfig")) |value| {
            try request_object.put("inferenceConfig", value);
        }
        if (parsed.value.object.get("guardrailConfig")) |value| {
            try request_object.put("guardrailConfig", value);
        }

        const root: std.json.Value = .{ .object = request_object };
        return std.json.Stringify.valueAlloc(allocator, root, .{});
    }

    pub fn extractResponseText(
        allocator: std.mem.Allocator,
        response_json: []const u8,
    ) ConnectorError![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_json, .{}) catch {
            return ConnectorError.InvalidResponse;
        };
        defer parsed.deinit();

        if (parsed.value != .object) return ConnectorError.InvalidResponse;
        const output_value = parsed.value.object.get("output") orelse return ConnectorError.InvalidResponse;
        if (output_value != .object) return ConnectorError.InvalidResponse;
        const message_value = output_value.object.get("message") orelse return ConnectorError.InvalidResponse;
        if (message_value != .object) return ConnectorError.InvalidResponse;

        const role_value = message_value.object.get("role") orelse return ConnectorError.InvalidResponse;
        if (role_value != .string or !std.mem.eql(u8, role_value.string, "assistant")) {
            return ConnectorError.InvalidResponse;
        }

        const content_value = message_value.object.get("content") orelse return ConnectorError.InvalidResponse;
        if (content_value != .array or content_value.array.items.len < 1) {
            return ConnectorError.InvalidResponse;
        }

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(allocator);

        var first_text = true;
        for (content_value.array.items) |item| {
            if (item != .object) continue;
            const text_value = item.object.get("text") orelse continue;
            if (text_value != .string) continue;
            if (!first_text) try out.appendSlice(allocator, "\n\n");
            try out.appendSlice(allocator, text_value.string);
            first_text = false;
        }

        return out.toOwnedSlice(allocator);
    }

    pub fn invoke(
        allocator: std.mem.Allocator,
        connector: *const entities.ConnectorEntity,
        prompt: []const u8,
    ) ConnectorError![]u8 {
        var creds = try loadAwsCredentials(allocator);
        defer creds.deinit(allocator);

        const region = try regionFromParamsOrEnv(
            allocator,
            connector.params_json,
            default_bedrock_region,
        );
        defer allocator.free(region);

        const request_json = try buildRequestJson(allocator, connector, prompt);
        defer allocator.free(request_json);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, request_json, .{}) catch {
            return ConnectorError.InvalidParamsJson;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return ConnectorError.InvalidParamsJson;

        const model_id_value = parsed.value.object.get("modelId") orelse return ConnectorError.InvalidParamsJson;
        if (model_id_value != .string or model_id_value.string.len == 0) {
            return ConnectorError.InvalidParamsJson;
        }
        const model_id = model_id_value.string;

        var body_obj = std.json.ObjectMap.init(parsed.arena.allocator());
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "modelId")) continue;
            body_obj.put(entry.key_ptr.*, entry.value_ptr.*) catch return ConnectorError.OutOfMemory;
        }
        const body_value: std.json.Value = .{ .object = body_obj };
        const body_json = std.json.Stringify.valueAlloc(
            allocator,
            body_value,
            .{},
        ) catch return ConnectorError.OutOfMemory;
        defer allocator.free(body_json);

        const endpoint_base = try bedrockEndpointBase(
            allocator,
            region,
            connector.model_endpoint,
        );
        defer allocator.free(endpoint_base);

        const path = try std.fmt.allocPrint(allocator, "/model/{s}/converse", .{model_id});
        defer allocator.free(path);
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ endpoint_base, path });
        defer allocator.free(url);

        const response_json = try postJsonAwsSigV4(
            allocator,
            url,
            body_json,
            "bedrock",
            region,
            &creds,
        );
        defer allocator.free(response_json);

        return extractResponseText(allocator, response_json);
    }
};

pub const SageMakerConfig = struct {
    region: []u8,
    model: []u8,

    pub fn deinit(self: *SageMakerConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.region);
        allocator.free(self.model);
    }
};

pub const AWSSageMakerAdapter = struct {
    pub fn configure(
        allocator: std.mem.Allocator,
        connector: *const entities.ConnectorEntity,
    ) ConnectorError!SageMakerConfig {
        if (connector.model.len == 0) return ConnectorError.MissingEndpoint;

        var parsed = try parseParamsObject(allocator, connector.params_json);
        defer parsed.deinit();

        var region: []const u8 = default_sagemaker_region;
        if (parsed.value.object.get("session")) |session_value| {
            if (session_value == .object) {
                if (session_value.object.get("region_name")) |region_value| {
                    if (region_value == .string and region_value.string.len > 0) {
                        region = region_value.string;
                    }
                }
            }
        }

        return .{
            .region = try allocator.dupe(u8, region),
            .model = try allocator.dupe(u8, connector.model),
        };
    }

    pub fn endpointUrl(
        allocator: std.mem.Allocator,
        config: *const SageMakerConfig,
    ) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "https://runtime.sagemaker.{s}.amazonaws.com/endpoints/{s}/invocations",
            .{ config.region, config.model },
        );
    }

    pub fn buildPayloadJson(
        allocator: std.mem.Allocator,
        connector: *const entities.ConnectorEntity,
        prompt: []const u8,
    ) ConnectorError![]u8 {
        if (prompt.len == 0) return ConnectorError.EmptyPrompt;

        var parsed = try parseParamsObject(allocator, connector.params_json);
        defer parsed.deinit();
        const arena = parsed.arena.allocator();

        const connector_prompt = try buildConnectorPrompt(arena, connector, prompt);
        var payload_object = std.json.ObjectMap.init(arena);

        var messages = std.json.Array.init(arena);
        if (connector.system_prompt.len > 0) {
            try messages.append(try makeRoleContentMessage(arena, "system", connector.system_prompt));
        }
        try messages.append(try makeRoleContentMessage(arena, "user", connector_prompt));
        try payload_object.put("messages", .{ .array = messages });

        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            try payload_object.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        const root: std.json.Value = .{ .object = payload_object };
        return std.json.Stringify.valueAlloc(allocator, root, .{});
    }

    pub fn extractResponseText(
        allocator: std.mem.Allocator,
        response_json: []const u8,
    ) ConnectorError![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_json, .{}) catch {
            return ConnectorError.InvalidResponse;
        };
        defer parsed.deinit();

        if (parsed.value != .object) return ConnectorError.InvalidResponse;
        if (parsed.value.object.count() == 0) return ConnectorError.InvalidResponse;

        const choices_value = parsed.value.object.get("choices") orelse return ConnectorError.InvalidResponse;
        if (choices_value != .array or choices_value.array.items.len == 0) {
            return ConnectorError.InvalidResponse;
        }

        const first_choice = choices_value.array.items[0];
        if (first_choice != .object) return ConnectorError.InvalidResponse;
        const message_value = first_choice.object.get("message") orelse return ConnectorError.InvalidResponse;
        if (message_value != .object) return ConnectorError.InvalidResponse;
        const content_value = message_value.object.get("content") orelse return ConnectorError.InvalidResponse;
        if (content_value != .string) return ConnectorError.InvalidResponse;

        return allocator.dupe(u8, content_value.string);
    }

    pub fn invoke(
        allocator: std.mem.Allocator,
        connector: *const entities.ConnectorEntity,
        prompt: []const u8,
    ) ConnectorError![]u8 {
        var creds = try loadAwsCredentials(allocator);
        defer creds.deinit(allocator);

        var cfg = try configure(allocator, connector);
        defer cfg.deinit(allocator);

        const payload_json = try buildPayloadJson(allocator, connector, prompt);
        defer allocator.free(payload_json);

        const endpoint = try endpointUrl(allocator, &cfg);
        defer allocator.free(endpoint);

        const response_json = try postJsonAwsSigV4(
            allocator,
            endpoint,
            payload_json,
            "sagemaker",
            cfg.region,
            &creds,
        );
        defer allocator.free(response_json);

        return extractResponseText(allocator, response_json);
    }
};

pub const AICoreAdapter = struct {
    pub fn buildRequestJson(
        allocator: std.mem.Allocator,
        connector: *const entities.ConnectorEntity,
        prompt: []const u8,
    ) ConnectorError![]u8 {
        return OpenAIAdapter.buildRequestJson(allocator, connector, prompt);
    }

    pub fn extractResponseText(
        allocator: std.mem.Allocator,
        response_json: []const u8,
    ) ConnectorError![]u8 {
        return OpenAIAdapter.extractResponseText(allocator, response_json);
    }

    pub fn invoke(
        allocator: std.mem.Allocator,
        connector: *const entities.ConnectorEntity,
        prompt: []const u8,
    ) ConnectorError![]u8 {
        if (connector.model_endpoint.len == 0) return ConnectorError.MissingModelEndpoint;

        const request_json = try buildRequestJson(allocator, connector, prompt);
        defer allocator.free(request_json);

        var headers = std.ArrayListUnmanaged(std.http.Header){};
        defer headers.deinit(allocator);
        try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
        try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });

        const ai_token = envPreferred(&.{ "AICORE_AUTH_TOKEN", "AICORE_API_KEY", "OPENAI_API_KEY" });
        const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{ai_token});
        defer allocator.free(auth);
        try headers.append(allocator, .{ .name = "Authorization", .value = auth });

        const ai_resource_group = try aiCoreResourceGroup(allocator, connector.params_json);
        defer if (ai_resource_group) |value| allocator.free(value);
        if (ai_resource_group) |value| {
            try headers.append(allocator, .{ .name = "AI-Resource-Group", .value = value });
        }

        const response_json = try postJson(allocator, connector.model_endpoint, headers.items, request_json);
        defer allocator.free(response_json);

        return extractResponseText(allocator, response_json);
    }
};

pub const PrivateLLMAdapter = struct {
    pub fn buildRequestJson(
        allocator: std.mem.Allocator,
        connector: *const entities.ConnectorEntity,
        prompt: []const u8,
    ) ConnectorError![]u8 {
        return OpenAIAdapter.buildRequestJson(allocator, connector, prompt);
    }

    pub fn extractResponseText(
        allocator: std.mem.Allocator,
        response_json: []const u8,
    ) ConnectorError![]u8 {
        return OpenAIAdapter.extractResponseText(allocator, response_json);
    }

    pub fn invoke(
        allocator: std.mem.Allocator,
        connector: *const entities.ConnectorEntity,
        prompt: []const u8,
    ) ConnectorError![]u8 {
        if (connector.model_endpoint.len == 0) return ConnectorError.MissingModelEndpoint;

        const request_json = try buildRequestJson(allocator, connector, prompt);
        defer allocator.free(request_json);

        var headers = std.ArrayListUnmanaged(std.http.Header){};
        defer headers.deinit(allocator);
        try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
        try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });

        const token = envPreferred(&.{ "PRIVATE_LLM_API_KEY", "OPENAI_API_KEY" });
        const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        defer allocator.free(auth);
        try headers.append(allocator, .{ .name = "Authorization", .value = auth });

        const response_json = try postJson(allocator, connector.model_endpoint, headers.items, request_json);
        defer allocator.free(response_json);

        return extractResponseText(allocator, response_json);
    }
};

pub const LangchainOpenAIChatOpenAIAdapter = struct {
    pub fn getResponse(_: []const u8) ConnectorError!void {
        return ConnectorError.NotImplemented;
    }
};

fn parseParamsObject(
    allocator: std.mem.Allocator,
    params_json: []const u8,
) ConnectorError!std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, params_json, " \t\r\n");
    const source = if (trimmed.len == 0) "{}" else params_json;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch {
        return ConnectorError.InvalidParamsJson;
    };
    errdefer parsed.deinit();
    if (parsed.value != .object) return ConnectorError.ParamsMustBeObject;
    return parsed;
}

fn buildConnectorPrompt(
    allocator: std.mem.Allocator,
    connector: *const entities.ConnectorEntity,
    prompt: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}{s}",
        .{ connector.connector_pre_prompt, prompt, connector.connector_post_prompt },
    );
}

fn makeRoleContentMessage(
    allocator: std.mem.Allocator,
    role: []const u8,
    content: []const u8,
) !std.json.Value {
    var message = std.json.ObjectMap.init(allocator);
    try message.put("role", .{ .string = role });
    try message.put("content", .{ .string = content });
    return .{ .object = message };
}

fn hasRequiredKeys(object: std.json.ObjectMap, keys: []const []const u8) bool {
    for (keys) |key| {
        if (!object.contains(key)) return false;
    }
    return true;
}

fn extractChoicesMessageContent(
    allocator: std.mem.Allocator,
    response_json: []const u8,
) ConnectorError![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_json, .{}) catch {
        return ConnectorError.InvalidResponse;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return ConnectorError.InvalidResponse;
    const choices_value = parsed.value.object.get("choices") orelse return ConnectorError.InvalidResponse;
    if (choices_value != .array or choices_value.array.items.len < 1) return ConnectorError.InvalidResponse;
    const first_choice = choices_value.array.items[0];
    if (first_choice != .object) return ConnectorError.InvalidResponse;
    const message_value = first_choice.object.get("message") orelse return ConnectorError.InvalidResponse;
    if (message_value != .object) return ConnectorError.InvalidResponse;
    const content_value = message_value.object.get("content") orelse return ConnectorError.InvalidResponse;
    if (content_value != .string) return ConnectorError.InvalidResponse;
    return allocator.dupe(u8, content_value.string);
}

fn envOrEmpty(name: []const u8) []const u8 {
    return std.posix.getenv(name) orelse "";
}

fn envPreferred(names: []const []const u8) []const u8 {
    for (names) |name| {
        const value = std.posix.getenv(name) orelse continue;
        if (value.len > 0) return value;
    }
    return "";
}

fn resolveEndpoint(default_endpoint: []const u8, configured_endpoint: []const u8) []const u8 {
    return if (configured_endpoint.len > 0) configured_endpoint else default_endpoint;
}

const AwsCredentials = struct {
    access_key_id: []u8,
    secret_access_key: []u8,
    session_token: ?[]u8,

    fn deinit(self: *AwsCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.access_key_id);
        allocator.free(self.secret_access_key);
        if (self.session_token) |token| allocator.free(token);
    }
};

fn loadAwsCredentials(allocator: std.mem.Allocator) ConnectorError!AwsCredentials {
    const access_env = std.posix.getenv("AWS_ACCESS_KEY_ID") orelse return ConnectorError.MissingAwsCredentials;
    const secret_env = std.posix.getenv("AWS_SECRET_ACCESS_KEY") orelse return ConnectorError.MissingAwsCredentials;
    if (access_env.len == 0 or secret_env.len == 0) return ConnectorError.MissingAwsCredentials;

    const access_key_id = allocator.dupe(u8, access_env) catch return ConnectorError.OutOfMemory;
    errdefer allocator.free(access_key_id);
    const secret_access_key = allocator.dupe(u8, secret_env) catch return ConnectorError.OutOfMemory;
    errdefer allocator.free(secret_access_key);

    var token: ?[]u8 = null;
    if (std.posix.getenv("AWS_SESSION_TOKEN")) |env_token| {
        if (env_token.len > 0) {
            token = allocator.dupe(u8, env_token) catch return ConnectorError.OutOfMemory;
        }
    }

    return .{
        .access_key_id = access_key_id,
        .secret_access_key = secret_access_key,
        .session_token = token,
    };
}

fn regionFromParamsOrEnv(
    allocator: std.mem.Allocator,
    params_json: []const u8,
    default_region: []const u8,
) ConnectorError![]u8 {
    var parsed = try parseParamsObject(allocator, params_json);
    defer parsed.deinit();

    if (parsed.value.object.get("session")) |session_value| {
        if (session_value == .object) {
            if (session_value.object.get("region_name")) |region_value| {
                if (region_value == .string and region_value.string.len > 0) {
                    return allocator.dupe(u8, region_value.string) catch return ConnectorError.OutOfMemory;
                }
            }
        }
    }

    const env_region = envPreferred(&.{ "AWS_REGION", "AWS_DEFAULT_REGION" });
    if (env_region.len > 0) return allocator.dupe(u8, env_region) catch return ConnectorError.OutOfMemory;

    return allocator.dupe(u8, default_region) catch return ConnectorError.OutOfMemory;
}

fn bedrockEndpointBase(
    allocator: std.mem.Allocator,
    region: []const u8,
    configured: []const u8,
) ConnectorError![]u8 {
    if (configured.len > 0 and configured.len >= 8) {
        return allocator.dupe(u8, configured) catch return ConnectorError.OutOfMemory;
    }
    return std.fmt.allocPrint(
        allocator,
        "https://bedrock-runtime.{s}.amazonaws.com",
        .{region},
    ) catch return ConnectorError.OutOfMemory;
}

fn formatAwsDate(timestamp: i64) [8]u8 {
    var buf: [8]u8 = undefined;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    _ = std.fmt.bufPrint(&buf, "{d:0>4}{d:0>2}{d:0>2}", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
    }) catch unreachable;
    return buf;
}

fn formatAwsDateTime(timestamp: i64) [16]u8 {
    var buf: [16]u8 = undefined;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    _ = std.fmt.bufPrint(&buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
    return buf;
}

fn sha256Hex(input: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

fn deriveAwsSigV4SigningKey(
    allocator: std.mem.Allocator,
    secret_access_key: []const u8,
    date: []const u8,
    region: []const u8,
    service: []const u8,
) ConnectorError![32]u8 {
    const key_prefix = std.fmt.allocPrint(allocator, "AWS4{s}", .{secret_access_key}) catch {
        return ConnectorError.OutOfMemory;
    };
    defer allocator.free(key_prefix);

    var key1: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&key1, date, key_prefix);

    var key2: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&key2, region, &key1);

    var key3: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&key3, service, &key2);

    var key4: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&key4, "aws4_request", &key3);

    return key4;
}

fn hostHeaderValue(allocator: std.mem.Allocator, uri: std.Uri) ConnectorError![]u8 {
    var host_buf: [std.Uri.host_name_max]u8 = undefined;
    const host = uri.getHost(&host_buf) catch return ConnectorError.InvalidEndpointUrl;
    if (uri.port) |port| {
        return std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, port }) catch return ConnectorError.OutOfMemory;
    }
    return allocator.dupe(u8, host) catch return ConnectorError.OutOfMemory;
}

fn canonicalPathForSigV4(
    allocator: std.mem.Allocator,
    uri: std.Uri,
) ConnectorError![]u8 {
    const raw = std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(uri.path, .formatPath)}) catch {
        return ConnectorError.OutOfMemory;
    };
    errdefer allocator.free(raw);

    if (raw.len == 0) {
        allocator.free(raw);
        return allocator.dupe(u8, "/") catch return ConnectorError.OutOfMemory;
    }
    if (raw[0] == '/') return raw;

    const with_slash = std.fmt.allocPrint(allocator, "/{s}", .{raw}) catch {
        return ConnectorError.OutOfMemory;
    };
    allocator.free(raw);
    return with_slash;
}

fn canonicalQueryForSigV4(
    allocator: std.mem.Allocator,
    uri: std.Uri,
) ConnectorError![]u8 {
    if (uri.query) |query| {
        return std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(query, .formatQuery)}) catch {
            return ConnectorError.OutOfMemory;
        };
    }
    return allocator.dupe(u8, "") catch return ConnectorError.OutOfMemory;
}

fn postJsonAwsSigV4(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    service: []const u8,
    region: []const u8,
    creds: *const AwsCredentials,
) ConnectorError![]u8 {
    const uri = std.Uri.parse(url) catch return ConnectorError.InvalidEndpointUrl;
    const host = try hostHeaderValue(allocator, uri);
    defer allocator.free(host);

    const canonical_path = try canonicalPathForSigV4(allocator, uri);
    defer allocator.free(canonical_path);
    const canonical_query = try canonicalQueryForSigV4(allocator, uri);
    defer allocator.free(canonical_query);

    const payload_hash = sha256Hex(body);
    const now = std.time.timestamp();
    const date = formatAwsDate(now);
    const amz_date = formatAwsDateTime(now);

    const signed_headers = if (creds.session_token != null)
        "content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token"
    else
        "content-type;host;x-amz-content-sha256;x-amz-date";

    var canonical_headers = std.ArrayList(u8){};
    defer canonical_headers.deinit(allocator);
    try canonical_headers.appendSlice(allocator, "content-type:application/json\n");
    try canonical_headers.appendSlice(allocator, "host:");
    try canonical_headers.appendSlice(allocator, host);
    try canonical_headers.append(allocator, '\n');
    try canonical_headers.appendSlice(allocator, "x-amz-content-sha256:");
    try canonical_headers.appendSlice(allocator, payload_hash[0..]);
    try canonical_headers.append(allocator, '\n');
    try canonical_headers.appendSlice(allocator, "x-amz-date:");
    try canonical_headers.appendSlice(allocator, amz_date[0..]);
    try canonical_headers.append(allocator, '\n');
    if (creds.session_token) |session_token| {
        try canonical_headers.appendSlice(allocator, "x-amz-security-token:");
        try canonical_headers.appendSlice(allocator, session_token);
        try canonical_headers.append(allocator, '\n');
    }

    var canonical_request = std.ArrayList(u8){};
    defer canonical_request.deinit(allocator);
    try canonical_request.appendSlice(allocator, "POST\n");
    try canonical_request.appendSlice(allocator, canonical_path);
    try canonical_request.append(allocator, '\n');
    try canonical_request.appendSlice(allocator, canonical_query);
    try canonical_request.append(allocator, '\n');
    try canonical_request.appendSlice(allocator, canonical_headers.items);
    try canonical_request.append(allocator, '\n');
    try canonical_request.appendSlice(allocator, signed_headers);
    try canonical_request.append(allocator, '\n');
    try canonical_request.appendSlice(allocator, payload_hash[0..]);

    const canonical_hash = sha256Hex(canonical_request.items);
    const scope = std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}/aws4_request",
        .{ date[0..], region, service },
    ) catch return ConnectorError.OutOfMemory;
    defer allocator.free(scope);

    var string_to_sign = std.ArrayList(u8){};
    defer string_to_sign.deinit(allocator);
    try string_to_sign.appendSlice(allocator, "AWS4-HMAC-SHA256\n");
    try string_to_sign.appendSlice(allocator, amz_date[0..]);
    try string_to_sign.append(allocator, '\n');
    try string_to_sign.appendSlice(allocator, scope);
    try string_to_sign.append(allocator, '\n');
    try string_to_sign.appendSlice(allocator, canonical_hash[0..]);

    const signing_key = try deriveAwsSigV4SigningKey(
        allocator,
        creds.secret_access_key,
        date[0..],
        region,
        service,
    );
    var signature: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&signature, string_to_sign.items, &signing_key);
    const signature_hex = std.fmt.bytesToHex(signature, .lower);

    const authorization = std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
        .{ creds.access_key_id, scope, signed_headers, signature_hex[0..] },
    ) catch return ConnectorError.OutOfMemory;
    defer allocator.free(authorization);

    var headers = std.ArrayListUnmanaged(std.http.Header){};
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
    try headers.append(allocator, .{ .name = "Accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "Host", .value = host });
    try headers.append(allocator, .{ .name = "x-amz-content-sha256", .value = payload_hash[0..] });
    try headers.append(allocator, .{ .name = "x-amz-date", .value = amz_date[0..] });
    if (creds.session_token) |session_token| {
        try headers.append(allocator, .{ .name = "x-amz-security-token", .value = session_token });
    }
    try headers.append(allocator, .{ .name = "Authorization", .value = authorization });

    return postJson(allocator, url, headers.items, body);
}

fn anthropicVersionFromParams(
    allocator: std.mem.Allocator,
    params_json: []const u8,
) ConnectorError![]u8 {
    var parsed = try parseParamsObject(allocator, params_json);
    defer parsed.deinit();

    if (parsed.value.object.get("anthropic_version")) |value| {
        if (value == .string and value.string.len > 0) {
            return allocator.dupe(u8, value.string);
        }
    }

    return allocator.dupe(u8, default_anthropic_version);
}

fn aiCoreResourceGroup(
    allocator: std.mem.Allocator,
    params_json: []const u8,
) ConnectorError!?[]u8 {
    var parsed = try parseParamsObject(allocator, params_json);
    defer parsed.deinit();

    if (parsed.value.object.get("ai_resource_group")) |value| {
        if (value == .string and value.string.len > 0) {
            return try allocator.dupe(u8, value.string);
        }
    }

    if (parsed.value.object.get("resource_group")) |value| {
        if (value == .string and value.string.len > 0) {
            return try allocator.dupe(u8, value.string);
        }
    }

    const env_group = std.posix.getenv("AICORE_RESOURCE_GROUP") orelse return null;
    if (env_group.len == 0) return null;
    return try allocator.dupe(u8, env_group);
}

fn postJson(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const std.http.Header,
    body: []const u8,
) ConnectorError![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const parsed = std.Uri.parse(url) catch return ConnectorError.InvalidEndpointUrl;
    _ = parsed;

    var response_body: std.ArrayList(u8) = .{};
    defer response_body.deinit(allocator);
    var response_writer = response_body.writer(allocator);
    var response_writer_buf: [1024]u8 = undefined;
    var response_writer_adapter = response_writer.adaptToNewApi(&response_writer_buf);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = headers,
        .response_writer = &response_writer_adapter.new_interface,
    }) catch return ConnectorError.HttpRequestFailed;
    response_writer_adapter.new_interface.flush() catch return ConnectorError.HttpRequestFailed;

    const status_code: u16 = @intFromEnum(result.status);
    if (status_code < 200 or status_code >= 300) return ConnectorError.NonSuccessStatus;

    return response_body.toOwnedSlice(allocator) catch return ConnectorError.OutOfMemory;
}

fn runPython(
    allocator: std.mem.Allocator,
    code: []const u8,
    args: []const []const u8,
) ![]u8 {
    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);
    try argv.append(allocator, "python3");
    try argv.append(allocator, "-c");
    try argv.append(allocator, code);
    for (args) |arg| try argv.append(allocator, arg);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.PythonFailed;
    }
    return result.stdout;
}

fn normalizeJsonWithPython(allocator: std.mem.Allocator, json_text: []const u8) ![]u8 {
    return runPython(
        allocator,
        "import json,sys; sys.stdout.write(json.dumps(json.loads(sys.argv[1]), sort_keys=True, separators=(',',':')))",
        &.{json_text},
    );
}

const ConnectorSpec = struct {
    name: []const u8 = "conn",
    connector_adapter: []const u8 = "openai_adapter",
    model: []const u8 = "gpt-4o",
    model_endpoint: []const u8 = "",
    params_json: []const u8 = "{}",
    connector_pre_prompt: []const u8 = "",
    connector_post_prompt: []const u8 = "",
    system_prompt: []const u8 = "",
};

fn makeConnectorEntity(allocator: std.mem.Allocator, spec: ConnectorSpec) !entities.ConnectorEntity {
    return .{
        .name = try allocator.dupe(u8, spec.name),
        .connector_adapter = try allocator.dupe(u8, spec.connector_adapter),
        .model = try allocator.dupe(u8, spec.model),
        .model_endpoint = try allocator.dupe(u8, spec.model_endpoint),
        .params_json = try allocator.dupe(u8, spec.params_json),
        .connector_pre_prompt = try allocator.dupe(u8, spec.connector_pre_prompt),
        .connector_post_prompt = try allocator.dupe(u8, spec.connector_post_prompt),
        .system_prompt = try allocator.dupe(u8, spec.system_prompt),
    };
}

test "openai build request parity with python semantics" {
    const allocator = std.testing.allocator;
    var connector = try makeConnectorEntity(allocator, .{
        .params_json = "{\"temperature\":0.7,\"model\":\"old-model\",\"messages\":[{\"role\":\"user\",\"content\":\"old\"}]}",
        .connector_pre_prompt = "PRE:",
        .connector_post_prompt = ":POST",
        .system_prompt = "system-rules",
    });
    defer connector.deinit(allocator);

    const prompt = "hello";
    const zig_json = try OpenAIAdapter.buildRequestJson(allocator, &connector, prompt);
    defer allocator.free(zig_json);

    const zig_normalized = try normalizeJsonWithPython(allocator, zig_json);
    defer allocator.free(zig_normalized);

    const py_json = try runPython(
        allocator,
        "import json,sys; params=json.loads(sys.argv[1]); model=sys.argv[2]; pre=sys.argv[3]; prompt=sys.argv[4]; post=sys.argv[5]; system=sys.argv[6]; connector_prompt=f'{pre}{prompt}{post}'; request=[{'role':'system','content':system},{'role':'user','content':connector_prompt}] if system else [{'role':'user','content':connector_prompt}]; merged={**params,'model':model,'messages':request}; sys.stdout.write(json.dumps(merged, sort_keys=True, separators=(',',':')))",
        &.{ connector.params_json, connector.model, connector.connector_pre_prompt, prompt, connector.connector_post_prompt, connector.system_prompt },
    );
    defer allocator.free(py_json);

    try std.testing.expectEqualStrings(py_json, zig_normalized);
}

test "openai response extraction parity" {
    const allocator = std.testing.allocator;
    const response_json = "{\"choices\":[{\"message\":{\"content\":\"openai-ok\"}}]}";

    const zig = try OpenAIAdapter.extractResponseText(allocator, response_json);
    defer allocator.free(zig);

    const py = try runPython(
        allocator,
        "import json,sys; d=json.loads(sys.argv[1]); sys.stdout.write(d['choices'][0]['message']['content'])",
        &.{response_json},
    );
    defer allocator.free(py);

    try std.testing.expectEqualStrings(py, zig);
}

test "openai invalid response fails" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        ConnectorError.InvalidResponse,
        OpenAIAdapter.extractResponseText(allocator, "{\"choices\":[]}"),
    );
}

test "private llm build request parity with python semantics" {
    const allocator = std.testing.allocator;
    var connector = try makeConnectorEntity(allocator, .{
        .connector_adapter = "private_llm_adapter",
        .model = "private-model",
        .model_endpoint = "https://private.example/v1/chat/completions",
        .params_json = "{\"temperature\":0.1}",
        .connector_pre_prompt = "[",
        .connector_post_prompt = "]",
        .system_prompt = "policy",
    });
    defer connector.deinit(allocator);

    const prompt = "question";
    const zig_json = try PrivateLLMAdapter.buildRequestJson(allocator, &connector, prompt);
    defer allocator.free(zig_json);
    const zig_normalized = try normalizeJsonWithPython(allocator, zig_json);
    defer allocator.free(zig_normalized);

    const py_json = try runPython(
        allocator,
        "import json,sys; params=json.loads(sys.argv[1]); model=sys.argv[2]; pre=sys.argv[3]; prompt=sys.argv[4]; post=sys.argv[5]; system=sys.argv[6]; connector_prompt=f'{pre}{prompt}{post}'; request=[{'role':'system','content':system},{'role':'user','content':connector_prompt}] if system else [{'role':'user','content':connector_prompt}]; merged={**params,'model':model,'messages':request}; sys.stdout.write(json.dumps(merged, sort_keys=True, separators=(',',':')))",
        &.{ connector.params_json, connector.model, connector.connector_pre_prompt, prompt, connector.connector_post_prompt, connector.system_prompt },
    );
    defer allocator.free(py_json);

    try std.testing.expectEqualStrings(py_json, zig_normalized);
}

test "ai core build request parity with openai-style semantics" {
    const allocator = std.testing.allocator;
    var connector = try makeConnectorEntity(allocator, .{
        .connector_adapter = "ai_core_adapter",
        .model = "gpt-4o-mini",
        .model_endpoint = "https://aicore.example/v1/chat/completions",
        .params_json = "{\"temperature\":0.3,\"resource_group\":\"rg-a\"}",
        .connector_pre_prompt = "pre-",
        .connector_post_prompt = "-post",
        .system_prompt = "system",
    });
    defer connector.deinit(allocator);

    const prompt = "hi";
    const zig_json = try AICoreAdapter.buildRequestJson(allocator, &connector, prompt);
    defer allocator.free(zig_json);
    const zig_normalized = try normalizeJsonWithPython(allocator, zig_json);
    defer allocator.free(zig_normalized);

    const py_json = try runPython(
        allocator,
        "import json,sys; params=json.loads(sys.argv[1]); model=sys.argv[2]; pre=sys.argv[3]; prompt=sys.argv[4]; post=sys.argv[5]; system=sys.argv[6]; connector_prompt=f'{pre}{prompt}{post}'; request=[{'role':'system','content':system},{'role':'user','content':connector_prompt}] if system else [{'role':'user','content':connector_prompt}]; merged={**params,'model':model,'messages':request}; sys.stdout.write(json.dumps(merged, sort_keys=True, separators=(',',':')))",
        &.{ connector.params_json, connector.model, connector.connector_pre_prompt, prompt, connector.connector_post_prompt, connector.system_prompt },
    );
    defer allocator.free(py_json);

    try std.testing.expectEqualStrings(py_json, zig_normalized);
}

test "private llm and ai core invoke requires explicit model endpoint" {
    const allocator = std.testing.allocator;

    var private_missing_endpoint = try makeConnectorEntity(allocator, .{
        .connector_adapter = "private_llm_adapter",
        .model_endpoint = "",
    });
    defer private_missing_endpoint.deinit(allocator);
    try std.testing.expectError(
        ConnectorError.MissingModelEndpoint,
        PrivateLLMAdapter.invoke(allocator, &private_missing_endpoint, "hello"),
    );

    var ai_core_missing_endpoint = try makeConnectorEntity(allocator, .{
        .connector_adapter = "ai_core_adapter",
        .model_endpoint = "",
    });
    defer ai_core_missing_endpoint.deinit(allocator);
    try std.testing.expectError(
        ConnectorError.MissingModelEndpoint,
        AICoreAdapter.invoke(allocator, &ai_core_missing_endpoint, "hello"),
    );
}

test "anthropic configuration validation branches" {
    const allocator = std.testing.allocator;

    var missing_max = try makeConnectorEntity(allocator, .{
        .connector_adapter = "anthropic_adapter",
        .model = "claude-sonnet",
        .params_json = "{}",
    });
    defer missing_max.deinit(allocator);
    try std.testing.expectError(
        ConnectorError.MissingMaxTokens,
        AnthropicAdapter.validateConfiguration(allocator, &missing_max),
    );

    var bad_max_type = try makeConnectorEntity(allocator, .{
        .connector_adapter = "anthropic_adapter",
        .model = "claude-sonnet",
        .params_json = "{\"max_tokens\":\"100\"}",
    });
    defer bad_max_type.deinit(allocator);
    try std.testing.expectError(
        ConnectorError.InvalidMaxTokens,
        AnthropicAdapter.validateConfiguration(allocator, &bad_max_type),
    );

    var missing_model = try makeConnectorEntity(allocator, .{
        .connector_adapter = "anthropic_adapter",
        .model = "",
        .params_json = "{\"max_tokens\":128}",
    });
    defer missing_model.deinit(allocator);
    try std.testing.expectError(
        ConnectorError.MissingModel,
        AnthropicAdapter.validateConfiguration(allocator, &missing_model),
    );

    var ok = try makeConnectorEntity(allocator, .{
        .connector_adapter = "anthropic_adapter",
        .model = "claude-sonnet",
        .params_json = "{\"max_tokens\":128}",
    });
    defer ok.deinit(allocator);
    try AnthropicAdapter.validateConfiguration(allocator, &ok);
}

test "anthropic build request parity with python semantics" {
    const allocator = std.testing.allocator;
    var connector = try makeConnectorEntity(allocator, .{
        .connector_adapter = "anthropic_adapter",
        .model = "claude-sonnet",
        .params_json = "{\"max_tokens\":128,\"temperature\":0.2}",
        .connector_pre_prompt = "prefix-",
        .connector_post_prompt = "-suffix",
        .system_prompt = "be concise",
    });
    defer connector.deinit(allocator);
    try AnthropicAdapter.validateConfiguration(allocator, &connector);

    const prompt = "prompt";
    const zig_json = try AnthropicAdapter.buildRequestJson(allocator, &connector, prompt);
    defer allocator.free(zig_json);

    const zig_normalized = try normalizeJsonWithPython(allocator, zig_json);
    defer allocator.free(zig_normalized);

    const py_json = try runPython(
        allocator,
        "import json,sys; params=json.loads(sys.argv[1]); model=sys.argv[2]; pre=sys.argv[3]; prompt=sys.argv[4]; post=sys.argv[5]; system=sys.argv[6]; connector_prompt=pre+prompt+post; out={**params,'model':model,'system':system,'messages':[{'role':'user','content':connector_prompt}]}; required=['model','max_tokens','messages']; assert all(k in out for k in required); sys.stdout.write(json.dumps(out, sort_keys=True, separators=(',',':')))",
        &.{ connector.params_json, connector.model, connector.connector_pre_prompt, prompt, connector.connector_post_prompt, connector.system_prompt },
    );
    defer allocator.free(py_json);

    try std.testing.expectEqualStrings(py_json, zig_normalized);
}

test "anthropic response extraction parity" {
    const allocator = std.testing.allocator;
    const response_json = "{\"content\":[{\"text\":\"anthropic-ok\"}]}";
    const zig = try AnthropicAdapter.extractResponseText(allocator, response_json);
    defer allocator.free(zig);

    const py = try runPython(
        allocator,
        "import json,sys; d=json.loads(sys.argv[1]); sys.stdout.write(d['content'][0]['text'])",
        &.{response_json},
    );
    defer allocator.free(py);

    try std.testing.expectEqualStrings(py, zig);
}

test "bedrock build request parity with python semantics" {
    const allocator = std.testing.allocator;
    var connector = try makeConnectorEntity(allocator, .{
        .connector_adapter = "aws_bedrock_adapter",
        .model = "anthropic.claude-3-haiku-20240307-v1:0",
        .params_json = "{\"timeout\":300,\"inferenceConfig\":{\"maxTokens\":256},\"guardrailConfig\":{\"trace\":\"enabled\"}}",
        .connector_pre_prompt = "pre ",
        .connector_post_prompt = " post",
    });
    defer connector.deinit(allocator);

    const prompt = "ask";
    const zig_json = try AWSBedrockAdapter.buildRequestJson(allocator, &connector, prompt);
    defer allocator.free(zig_json);

    const zig_normalized = try normalizeJsonWithPython(allocator, zig_json);
    defer allocator.free(zig_normalized);

    const py_json = try runPython(
        allocator,
        "import json,sys; params=json.loads(sys.argv[1]); model=sys.argv[2]; pre=sys.argv[3]; prompt=sys.argv[4]; post=sys.argv[5]; connector_prompt=f'{pre}{prompt}{post}'; req={'modelId':model,'messages':[{'role':'user','content':[{'text':connector_prompt}]}]};\nfor key in ['inferenceConfig','guardrailConfig']:\n    if key in params:\n        req[key]=params[key]\nsys.stdout.write(json.dumps(req, sort_keys=True, separators=(',',':')))",
        &.{ connector.params_json, connector.model, connector.connector_pre_prompt, prompt, connector.connector_post_prompt },
    );
    defer allocator.free(py_json);

    try std.testing.expectEqualStrings(py_json, zig_normalized);
}

test "bedrock response extraction parity and validation" {
    const allocator = std.testing.allocator;
    const response_json = "{\"output\":{\"message\":{\"role\":\"assistant\",\"content\":[{\"text\":\"line1\"},{\"image\":\"ignore\"},{\"text\":\"line2\"}]}}}";

    const zig = try AWSBedrockAdapter.extractResponseText(allocator, response_json);
    defer allocator.free(zig);

    const py = try runPython(
        allocator,
        "import json,sys; message=json.loads(sys.argv[1])['output']['message'];\nif (not message) or message['role']!='assistant' or len(message['content'])<1: raise ValueError('invalid');\nsys.stdout.write('\\n\\n'.join([m['text'] for m in message['content'] if 'text' in m]))",
        &.{response_json},
    );
    defer allocator.free(py);

    try std.testing.expectEqualStrings(py, zig);

    try std.testing.expectError(
        ConnectorError.InvalidResponse,
        AWSBedrockAdapter.extractResponseText(allocator, "{\"output\":{\"message\":{\"role\":\"user\",\"content\":[{\"text\":\"x\"}]}}}"),
    );
}

test "sagemaker configure defaults and endpoint url" {
    const allocator = std.testing.allocator;

    var with_default_region = try makeConnectorEntity(allocator, .{
        .connector_adapter = "aws_sagemaker_adapter",
        .model = "my-model",
        .params_json = "{}",
    });
    defer with_default_region.deinit(allocator);

    var cfg = try AWSSageMakerAdapter.configure(allocator, &with_default_region);
    defer cfg.deinit(allocator);
    try std.testing.expectEqualStrings("ap-southeast-1", cfg.region);
    try std.testing.expectEqualStrings("my-model", cfg.model);

    const endpoint = try AWSSageMakerAdapter.endpointUrl(allocator, &cfg);
    defer allocator.free(endpoint);
    try std.testing.expectEqualStrings(
        "https://runtime.sagemaker.ap-southeast-1.amazonaws.com/endpoints/my-model/invocations",
        endpoint,
    );

    var with_custom_region = try makeConnectorEntity(allocator, .{
        .connector_adapter = "aws_sagemaker_adapter",
        .model = "my-model",
        .params_json = "{\"session\":{\"region_name\":\"us-east-1\"}}",
    });
    defer with_custom_region.deinit(allocator);
    var cfg_custom = try AWSSageMakerAdapter.configure(allocator, &with_custom_region);
    defer cfg_custom.deinit(allocator);
    try std.testing.expectEqualStrings("us-east-1", cfg_custom.region);

    var missing_model = try makeConnectorEntity(allocator, .{
        .connector_adapter = "aws_sagemaker_adapter",
        .model = "",
        .params_json = "{}",
    });
    defer missing_model.deinit(allocator);
    try std.testing.expectError(
        ConnectorError.MissingEndpoint,
        AWSSageMakerAdapter.configure(allocator, &missing_model),
    );
}

test "sagemaker payload parity with python update semantics" {
    const allocator = std.testing.allocator;
    var connector = try makeConnectorEntity(allocator, .{
        .connector_adapter = "aws_sagemaker_adapter",
        .model = "gpt-4o-mini",
        .params_json = "{\"timeout\":300,\"messages\":[{\"role\":\"user\",\"content\":\"override\"}]}",
        .connector_pre_prompt = "<",
        .connector_post_prompt = ">",
        .system_prompt = "system-rule",
    });
    defer connector.deinit(allocator);

    const prompt = "body";
    const zig_json = try AWSSageMakerAdapter.buildPayloadJson(allocator, &connector, prompt);
    defer allocator.free(zig_json);

    const zig_normalized = try normalizeJsonWithPython(allocator, zig_json);
    defer allocator.free(zig_normalized);

    const py_json = try runPython(
        allocator,
        "import json,sys; params=json.loads(sys.argv[1]); pre=sys.argv[2]; prompt=sys.argv[3]; post=sys.argv[4]; system=sys.argv[5]; connector_prompt=f'{pre}{prompt}{post}'; payload={'messages':[{'role':'system','content':system},{'role':'user','content':connector_prompt}]} if system else {'messages':[{'role':'user','content':connector_prompt}]}; payload.update(params); sys.stdout.write(json.dumps(payload, sort_keys=True, separators=(',',':')))",
        &.{ connector.params_json, connector.connector_pre_prompt, prompt, connector.connector_post_prompt, connector.system_prompt },
    );
    defer allocator.free(py_json);

    try std.testing.expectEqualStrings(py_json, zig_normalized);
}

test "sagemaker payload empty prompt and response extraction parity" {
    const allocator = std.testing.allocator;
    var connector = try makeConnectorEntity(allocator, .{
        .connector_adapter = "aws_sagemaker_adapter",
        .params_json = "{\"timeout\":300}",
    });
    defer connector.deinit(allocator);

    try std.testing.expectError(
        ConnectorError.EmptyPrompt,
        AWSSageMakerAdapter.buildPayloadJson(allocator, &connector, ""),
    );

    const response_json = "{\"choices\":[{\"message\":{\"content\":\"sagemaker-ok\"}}]}";
    const zig = try AWSSageMakerAdapter.extractResponseText(allocator, response_json);
    defer allocator.free(zig);

    const py = try runPython(
        allocator,
        "import json,sys; d=json.loads(sys.argv[1]);\nif not d: raise ValueError('empty');\nif 'choices' not in d: raise ValueError('missing choices');\nif not d['choices']: raise ValueError('no choices');\nif 'message' not in d['choices'][0] or d['choices'][0]['message'] is None: raise ValueError('missing message');\nif 'content' not in d['choices'][0]['message'] or d['choices'][0]['message']['content'] is None: raise ValueError('missing content');\nsys.stdout.write(d['choices'][0]['message']['content'])",
        &.{response_json},
    );
    defer allocator.free(py);
    try std.testing.expectEqualStrings(py, zig);

    try std.testing.expectError(
        ConnectorError.InvalidResponse,
        AWSSageMakerAdapter.extractResponseText(allocator, "{\"choices\":[]}"),
    );
}

test "bedrock and sagemaker invoke require aws credentials" {
    const allocator = std.testing.allocator;
    const has_access = if (std.posix.getenv("AWS_ACCESS_KEY_ID")) |v| v.len > 0 else false;
    const has_secret = if (std.posix.getenv("AWS_SECRET_ACCESS_KEY")) |v| v.len > 0 else false;
    if (has_access and has_secret) return error.SkipZigTest;

    var bedrock = try makeConnectorEntity(allocator, .{
        .connector_adapter = "aws_bedrock_adapter",
        .model = "anthropic.claude-3-haiku-20240307-v1:0",
    });
    defer bedrock.deinit(allocator);

    try std.testing.expectError(
        ConnectorError.MissingAwsCredentials,
        AWSBedrockAdapter.invoke(allocator, &bedrock, "hello"),
    );

    var sagemaker = try makeConnectorEntity(allocator, .{
        .connector_adapter = "aws_sagemaker_adapter",
        .model = "gpt-4o-mini",
    });
    defer sagemaker.deinit(allocator);

    try std.testing.expectError(
        ConnectorError.MissingAwsCredentials,
        AWSSageMakerAdapter.invoke(allocator, &sagemaker, "hello"),
    );
}

test "langchain openai adapter get_response is not implemented" {
    try std.testing.expectError(
        ConnectorError.NotImplemented,
        LangchainOpenAIChatOpenAIAdapter.getResponse("any"),
    );
}
