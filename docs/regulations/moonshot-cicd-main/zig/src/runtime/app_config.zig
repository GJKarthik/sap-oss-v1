const std = @import("std");
const entities = @import("../domain/entities.zig");
const config_loader = @import("config_loader.zig");

pub const AppConfigError = error{
    OutOfMemory,
    ConfigLoadFailed,
    InvalidConfigJson,
    InvalidConfigRoot,
    InvalidConnectorConfig,
    InvalidMetricConfig,
    InvalidAttackModuleConfig,
};

pub const MetricConfig = struct {
    name: []u8,
    connector_configurations: entities.ConnectorEntity,
    params_json: []u8,

    pub fn deinit(self: *MetricConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.connector_configurations.deinit(allocator);
        allocator.free(self.params_json);
    }
};

pub const AttackModuleNamedConnector = struct {
    key: []u8,
    connector: entities.ConnectorEntity,

    fn deinit(self: *AttackModuleNamedConnector, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        self.connector.deinit(allocator);
    }
};

pub const AttackModuleConfig = struct {
    name: []u8,
    connector_configurations: std.ArrayListUnmanaged(AttackModuleNamedConnector),
    params_json: []u8,

    pub fn deinit(self: *AttackModuleConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.connector_configurations.items) |*entry| {
            entry.deinit(allocator);
        }
        self.connector_configurations.deinit(allocator);
        allocator.free(self.params_json);
    }
};

pub const AppConfig = struct {
    pub const CONFIG_PATH_ENV_VAR = "MS_CONFIG_PATH";
    pub const TEST_CONFIG_PATH_ENV_VAR = "MS_TEST_CONFIG_PATH";
    pub const DEFAULT_CONFIG_PATH = "moonshot_config.yaml";

    pub const DEFAULT_DATA_PATH = "data";
    pub const DEFAULT_TEST_CONFIGS_FILE = "tests.yaml";
    pub const DEFAULT_DATASETS_PATH = "data/datasets";
    pub const DEFAULT_ATTACK_MODULES_PATH = "data/attack_modules";
    pub const DEFAULT_RESULTS_PATH = "data/results";
    pub const DEFAULT_TEST_CONFIGS_PATH = "data/test_configs";
    pub const DEFAULT_ADAPTERS_PATH = "src/adapters";
    pub const DEFAULT_TEMP_PATH = "src/temp";

    allocator: std.mem.Allocator,
    json_text: []u8,
    parsed: std.json.Parsed(std.json.Value),

    pub fn fromJsonText(
        allocator: std.mem.Allocator,
        json_text: []const u8,
    ) AppConfigError!AppConfig {
        const owned_json = allocator.dupe(u8, json_text) catch return AppConfigError.OutOfMemory;
        errdefer allocator.free(owned_json);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, owned_json, .{}) catch {
            return AppConfigError.InvalidConfigJson;
        };
        errdefer parsed.deinit();

        if (parsed.value != .object) return AppConfigError.InvalidConfigRoot;

        return .{
            .allocator = allocator,
            .json_text = owned_json,
            .parsed = parsed,
        };
    }

    pub fn load(
        allocator: std.mem.Allocator,
        project_root: []const u8,
    ) AppConfigError!AppConfig {
        const config_path = std.posix.getenv(CONFIG_PATH_ENV_VAR) orelse DEFAULT_CONFIG_PATH;
        return loadFromPath(
            allocator,
            project_root,
            config_path,
        );
    }

    pub fn loadFromPath(
        allocator: std.mem.Allocator,
        project_root: []const u8,
        config_path: []const u8,
    ) AppConfigError!AppConfig {
        const json_text = config_loader.loadJsonFromConfigPath(
            allocator,
            project_root,
            config_path,
        ) catch return AppConfigError.ConfigLoadFailed;
        errdefer allocator.free(json_text);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch {
            return AppConfigError.InvalidConfigJson;
        };
        errdefer parsed.deinit();

        if (parsed.value != .object) return AppConfigError.InvalidConfigRoot;

        return .{
            .allocator = allocator,
            .json_text = json_text,
            .parsed = parsed,
        };
    }

    pub fn deinit(self: *AppConfig) void {
        self.parsed.deinit();
        self.allocator.free(self.json_text);
    }

    pub fn getTestConfigFilePath() []const u8 {
        return std.posix.getenv(TEST_CONFIG_PATH_ENV_VAR) orelse DEFAULT_TEST_CONFIGS_FILE;
    }

    pub fn getCommonConfigI64(self: *const AppConfig, common_config_name: []const u8) ?i64 {
        const default_value = defaultCommonConfigValue(common_config_name);
        const common_value = self.rootObject().get("common") orelse return default_value;
        if (common_value != .object) return default_value;
        return parseI64(common_value.object.get(common_config_name)) orelse default_value;
    }

    pub fn getConnectorConfig(
        self: *const AppConfig,
        allocator: std.mem.Allocator,
        connector_config_name: []const u8,
    ) AppConfigError!?entities.ConnectorEntity {
        const connectors_value = self.rootObject().get("connectors_configurations") orelse return null;
        if (connectors_value != .array) return AppConfigError.InvalidConnectorConfig;

        for (connectors_value.array.items) |item| {
            if (item != .object) continue;
            const name_value = item.object.get("name") orelse continue;
            if (name_value != .string) continue;
            if (!std.mem.eql(u8, name_value.string, connector_config_name)) continue;

            return try parseConnectorEntityFromObject(
                allocator,
                item.object,
                connector_config_name,
                false,
                AppConfigError.InvalidConnectorConfig,
            );
        }
        return null;
    }

    pub fn getMetricConfig(
        self: *const AppConfig,
        allocator: std.mem.Allocator,
        metric_name: []const u8,
    ) AppConfigError!?MetricConfig {
        const metrics_value = self.rootObject().get("metrics") orelse return null;
        if (metrics_value != .array) return AppConfigError.InvalidMetricConfig;

        for (metrics_value.array.items) |item| {
            if (item != .object) continue;
            const name_value = item.object.get("name") orelse continue;
            if (name_value != .string) continue;
            if (!std.mem.eql(u8, name_value.string, metric_name)) continue;

            const connector_value = item.object.get("connector_configurations") orelse {
                return AppConfigError.InvalidMetricConfig;
            };
            if (connector_value != .object) return AppConfigError.InvalidMetricConfig;

            var connector_entity = try parseConnectorEntityFromObject(
                allocator,
                connector_value.object,
                "",
                true,
                AppConfigError.InvalidMetricConfig,
            );
            errdefer connector_entity.deinit(allocator);

            const params_json = try stringifyObjectFieldOrDefault(
                allocator,
                item.object,
                "params",
                "{}",
                AppConfigError.InvalidMetricConfig,
            );
            errdefer allocator.free(params_json);

            const metric_name_copy = allocator.dupe(u8, name_value.string) catch {
                return AppConfigError.OutOfMemory;
            };
            errdefer allocator.free(metric_name_copy);

            return .{
                .name = metric_name_copy,
                .connector_configurations = connector_entity,
                .params_json = params_json,
            };
        }
        return null;
    }

    pub fn getAttackModuleConfig(
        self: *const AppConfig,
        allocator: std.mem.Allocator,
        attack_module_name: []const u8,
    ) AppConfigError!?AttackModuleConfig {
        const modules_value = self.rootObject().get("attack_modules") orelse return null;
        if (modules_value != .array) return AppConfigError.InvalidAttackModuleConfig;

        for (modules_value.array.items) |item| {
            if (item != .object) continue;
            const name_value = item.object.get("name") orelse continue;
            if (name_value != .string) continue;
            if (!std.mem.eql(u8, name_value.string, attack_module_name)) continue;

            const connectors_value = item.object.get("connector_configurations") orelse {
                return AppConfigError.InvalidAttackModuleConfig;
            };
            if (connectors_value != .object) return AppConfigError.InvalidAttackModuleConfig;

            const module_name = allocator.dupe(u8, name_value.string) catch {
                return AppConfigError.OutOfMemory;
            };
            errdefer allocator.free(module_name);

            const params_json = try stringifyObjectFieldOrDefault(
                allocator,
                item.object,
                "params",
                "{}",
                AppConfigError.InvalidAttackModuleConfig,
            );
            errdefer allocator.free(params_json);

            var connector_entries = std.ArrayListUnmanaged(AttackModuleNamedConnector){};
            errdefer {
                for (connector_entries.items) |*entry| entry.deinit(allocator);
                connector_entries.deinit(allocator);
            }

            var it = connectors_value.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .object) return AppConfigError.InvalidAttackModuleConfig;
                const key_copy = allocator.dupe(u8, entry.key_ptr.*) catch return AppConfigError.OutOfMemory;
                errdefer allocator.free(key_copy);

                var connector_entity = try parseConnectorEntityFromObject(
                    allocator,
                    entry.value_ptr.*.object,
                    entry.key_ptr.*,
                    true,
                    AppConfigError.InvalidAttackModuleConfig,
                );
                errdefer connector_entity.deinit(allocator);

                connector_entries.append(allocator, .{
                    .key = key_copy,
                    .connector = connector_entity,
                }) catch return AppConfigError.OutOfMemory;
            }

            return .{
                .name = module_name,
                .connector_configurations = connector_entries,
                .params_json = params_json,
            };
        }

        return null;
    }

    fn rootObject(self: *const AppConfig) std.json.ObjectMap {
        return self.parsed.value.object;
    }
};

fn parseI64(maybe_value: ?std.json.Value) ?i64 {
    const value = maybe_value orelse return null;
    return switch (value) {
        .integer => |v| v,
        .float => |v| @intFromFloat(v),
        else => null,
    };
}

fn defaultCommonConfigValue(common_config_name: []const u8) ?i64 {
    if (std.mem.eql(u8, common_config_name, "max_concurrency")) return 5;
    if (std.mem.eql(u8, common_config_name, "max_calls_per_minute")) return 60;
    if (std.mem.eql(u8, common_config_name, "max_attempts")) return 3;
    return null;
}

fn parseConnectorEntityFromObject(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    fallback_name: []const u8,
    require_adapter_and_model: bool,
    comptime invalid_error: AppConfigError,
) AppConfigError!entities.ConnectorEntity {
    const name = try dupStringFieldOrDefault(
        allocator,
        object,
        "name",
        fallback_name,
        false,
    ) orelse return invalid_error;
    errdefer allocator.free(name);

    const connector_adapter = try dupStringFieldOrDefault(
        allocator,
        object,
        "connector_adapter",
        "",
        require_adapter_and_model,
    ) orelse return invalid_error;
    errdefer allocator.free(connector_adapter);

    const model = try dupStringFieldOrDefault(
        allocator,
        object,
        "model",
        "",
        require_adapter_and_model,
    ) orelse return invalid_error;
    errdefer allocator.free(model);

    const model_endpoint = try dupStringFieldOrDefault(
        allocator,
        object,
        "model_endpoint",
        "",
        false,
    ) orelse return invalid_error;
    errdefer allocator.free(model_endpoint);

    const params_json = try stringifyConnectorParamsOrDefault(
        allocator,
        object,
        "params",
        "{}",
        invalid_error,
    );
    errdefer allocator.free(params_json);

    const connector_pre_prompt = try dupStringFieldOrDefault(
        allocator,
        object,
        "connector_pre_prompt",
        "",
        false,
    ) orelse return invalid_error;
    errdefer allocator.free(connector_pre_prompt);

    const connector_post_prompt = try dupStringFieldOrDefault(
        allocator,
        object,
        "connector_post_prompt",
        "",
        false,
    ) orelse return invalid_error;
    errdefer allocator.free(connector_post_prompt);

    const system_prompt = try dupStringFieldOrDefault(
        allocator,
        object,
        "system_prompt",
        "",
        false,
    ) orelse return invalid_error;
    errdefer allocator.free(system_prompt);

    return .{
        .name = name,
        .connector_adapter = connector_adapter,
        .model = model,
        .model_endpoint = model_endpoint,
        .params_json = params_json,
        .connector_pre_prompt = connector_pre_prompt,
        .connector_post_prompt = connector_post_prompt,
        .system_prompt = system_prompt,
    };
}

fn dupStringFieldOrDefault(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
    default_value: []const u8,
    required: bool,
) AppConfigError!?[]u8 {
    if (object.get(key)) |value| {
        if (value != .string) return null;
        return allocator.dupe(u8, value.string) catch return AppConfigError.OutOfMemory;
    }
    if (required) return null;
    return allocator.dupe(u8, default_value) catch return AppConfigError.OutOfMemory;
}

fn stringifyObjectFieldOrDefault(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
    default_json: []const u8,
    comptime invalid_error: AppConfigError,
) AppConfigError![]u8 {
    const value = object.get(key) orelse {
        return allocator.dupe(u8, default_json) catch return AppConfigError.OutOfMemory;
    };
    if (value != .object) return invalid_error;
    return std.json.Stringify.valueAlloc(allocator, value, .{}) catch return AppConfigError.OutOfMemory;
}

fn stringifyConnectorParamsOrDefault(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
    default_json: []const u8,
    comptime invalid_error: AppConfigError,
) AppConfigError![]u8 {
    const value = object.get(key) orelse {
        return allocator.dupe(u8, default_json) catch return AppConfigError.OutOfMemory;
    };

    switch (value) {
        .object => {
            return std.json.Stringify.valueAlloc(allocator, value, .{}) catch return AppConfigError.OutOfMemory;
        },
        .array => |array_value| {
            var merged = std.json.ObjectMap.init(allocator);
            defer merged.deinit();

            for (array_value.items) |item| {
                if (item != .object) return invalid_error;
                var it = item.object.iterator();
                while (it.next()) |entry| {
                    merged.put(entry.key_ptr.*, entry.value_ptr.*) catch return AppConfigError.OutOfMemory;
                }
            }

            const merged_value: std.json.Value = .{ .object = merged };
            return std.json.Stringify.valueAlloc(allocator, merged_value, .{}) catch {
                return AppConfigError.OutOfMemory;
            };
        },
        else => return invalid_error,
    }
}

test "connector config retrieval and params merge parity" {
    const json_text =
        \\{
        \\  "connectors_configurations": [
        \\    {
        \\      "name": "test_connector_1",
        \\      "connector_adapter": "openai_adapter",
        \\      "model": "gpt-4o-mini",
        \\      "params": [
        \\        { "timeout": 300 },
        \\        { "session": { "region_name": "us-east-1" } }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var app_config = try AppConfig.fromJsonText(std.testing.allocator, json_text);
    defer app_config.deinit();

    var connector = (try app_config.getConnectorConfig(std.testing.allocator, "test_connector_1")) orelse {
        return error.TestExpectedEqual;
    };
    defer connector.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("openai_adapter", connector.connector_adapter);
    try std.testing.expectEqualStrings("gpt-4o-mini", connector.model);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, connector.params_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqual(@as(i64, 300), parsed.value.object.get("timeout").?.integer);
    try std.testing.expect(parsed.value.object.get("session").? == .object);
}

test "common config retrieval respects defaults parity" {
    const json_text =
        \\{
        \\  "connectors_configurations": []
        \\}
    ;

    var app_config = try AppConfig.fromJsonText(std.testing.allocator, json_text);
    defer app_config.deinit();

    try std.testing.expectEqual(@as(?i64, 5), app_config.getCommonConfigI64("max_concurrency"));
    try std.testing.expectEqual(@as(?i64, 60), app_config.getCommonConfigI64("max_calls_per_minute"));
    try std.testing.expectEqual(@as(?i64, 3), app_config.getCommonConfigI64("max_attempts"));
    try std.testing.expect(app_config.getCommonConfigI64("missing_key") == null);
}

test "connector config retrieval returns null when connector does not exist" {
    const json_text =
        \\{
        \\  "connectors_configurations": [
        \\    { "name": "test_connector_1", "connector_adapter": "openai_adapter", "model": "gpt-4o-mini" }
        \\  ]
        \\}
    ;

    var app_config = try AppConfig.fromJsonText(std.testing.allocator, json_text);
    defer app_config.deinit();

    try std.testing.expect((try app_config.getConnectorConfig(std.testing.allocator, "missing")) == null);
}

test "connector config retrieval fails when connector fields are invalid types" {
    const json_text =
        \\{
        \\  "connectors_configurations": [
        \\    { "name": "test_connector_1", "connector_adapter": [], "model": "gpt-4o-mini" }
        \\  ]
        \\}
    ;

    var app_config = try AppConfig.fromJsonText(std.testing.allocator, json_text);
    defer app_config.deinit();

    try std.testing.expectError(
        AppConfigError.InvalidConnectorConfig,
        app_config.getConnectorConfig(std.testing.allocator, "test_connector_1"),
    );
}

test "metric config retrieval parity" {
    const json_text =
        \\{
        \\  "metrics": [
        \\    {
        \\      "name": "refusal_adapter",
        \\      "connector_configurations": {
        \\        "connector_adapter": "openai_adapter",
        \\        "model": "gpt-4o-mini"
        \\      },
        \\      "params": {
        \\        "categorise_result": true
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var app_config = try AppConfig.fromJsonText(std.testing.allocator, json_text);
    defer app_config.deinit();

    var metric = (try app_config.getMetricConfig(std.testing.allocator, "refusal_adapter")) orelse {
        return error.TestExpectedEqual;
    };
    defer metric.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("refusal_adapter", metric.name);
    try std.testing.expectEqualStrings("openai_adapter", metric.connector_configurations.connector_adapter);
    try std.testing.expectEqualStrings("gpt-4o-mini", metric.connector_configurations.model);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, metric.params_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqual(true, parsed.value.object.get("categorise_result").?.bool);
}

test "metric config retrieval fails when connector_configurations is invalid type" {
    const json_text =
        \\{
        \\  "metrics": [
        \\    { "name": "refusal_adapter", "connector_configurations": "invalid" }
        \\  ]
        \\}
    ;

    var app_config = try AppConfig.fromJsonText(std.testing.allocator, json_text);
    defer app_config.deinit();

    try std.testing.expectError(
        AppConfigError.InvalidMetricConfig,
        app_config.getMetricConfig(std.testing.allocator, "refusal_adapter"),
    );
}

test "attack module config retrieval parity" {
    const json_text =
        \\{
        \\  "attack_modules": [
        \\    {
        \\      "name": "test_attack_module_1",
        \\      "connector_configurations": {
        \\        "prompt_generator_llm": {
        \\          "connector_adapter": "openai_adapter",
        \\          "model": "gpt-4o-mini"
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var app_config = try AppConfig.fromJsonText(std.testing.allocator, json_text);
    defer app_config.deinit();

    var attack_module = (try app_config.getAttackModuleConfig(std.testing.allocator, "test_attack_module_1")) orelse {
        return error.TestExpectedEqual;
    };
    defer attack_module.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test_attack_module_1", attack_module.name);
    try std.testing.expectEqual(@as(usize, 1), attack_module.connector_configurations.items.len);
    try std.testing.expectEqualStrings(
        "prompt_generator_llm",
        attack_module.connector_configurations.items[0].key,
    );
    try std.testing.expectEqualStrings(
        "openai_adapter",
        attack_module.connector_configurations.items[0].connector.connector_adapter,
    );
}

test "attack module config retrieval fails when connector_configurations is invalid type" {
    const json_text =
        \\{
        \\  "attack_modules": [
        \\    { "name": "test_attack_module_1", "connector_configurations": "invalid" }
        \\  ]
        \\}
    ;

    var app_config = try AppConfig.fromJsonText(std.testing.allocator, json_text);
    defer app_config.deinit();

    try std.testing.expectError(
        AppConfigError.InvalidAttackModuleConfig,
        app_config.getAttackModuleConfig(std.testing.allocator, "test_attack_module_1"),
    );
}

test "test config file path falls back to default when env var is not set" {
    if (std.posix.getenv(AppConfig.TEST_CONFIG_PATH_ENV_VAR) != null) return error.SkipZigTest;
    try std.testing.expectEqualStrings("tests.yaml", AppConfig.getTestConfigFilePath());
}
