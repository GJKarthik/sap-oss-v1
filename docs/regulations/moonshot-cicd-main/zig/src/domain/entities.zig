const std = @import("std");

pub const EntityError = error{
    InvalidJsonRoot,
    InvalidJsonField,
};

pub const CommonConfig = struct {
    max_concurrency: i64 = 5,
    max_calls_per_minute: i64 = 60,
    max_attempts: i64 = 3,
};

pub const ConnectorEntity = struct {
    name: []u8,
    connector_adapter: []u8,
    model: []u8,
    model_endpoint: []u8,
    params_json: []u8,
    connector_pre_prompt: []u8,
    connector_post_prompt: []u8,
    system_prompt: []u8,

    pub fn deinit(self: *ConnectorEntity, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.connector_adapter);
        allocator.free(self.model);
        allocator.free(self.model_endpoint);
        allocator.free(self.params_json);
        allocator.free(self.connector_pre_prompt);
        allocator.free(self.connector_post_prompt);
        allocator.free(self.system_prompt);
    }
};

pub const NamedEntity = struct {
    name: []u8,

    pub fn deinit(self: *NamedEntity, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const PromptEntity = struct {
    index: usize,
    prompt: []u8,
    target: []u8,
    reference_context: []u8,
    additional_info_json: []u8,

    pub fn deinit(self: *PromptEntity, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt);
        allocator.free(self.target);
        allocator.free(self.reference_context);
        allocator.free(self.additional_info_json);
    }
};

pub const DatasetEntity = struct {
    name: []u8,
    examples: std.ArrayListUnmanaged(PromptEntity),

    pub fn deinit(self: *DatasetEntity, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.examples.items) |*example| {
            example.deinit(allocator);
        }
        self.examples.deinit(allocator);
    }
};

pub const AppConfigEntity = struct {
    allocator: std.mem.Allocator,
    common: CommonConfig,
    connectors_configurations: std.ArrayListUnmanaged(ConnectorEntity),
    metrics: std.ArrayListUnmanaged(NamedEntity),
    attack_modules: std.ArrayListUnmanaged(NamedEntity),

    pub fn init(allocator: std.mem.Allocator) AppConfigEntity {
        return .{
            .allocator = allocator,
            .common = .{},
            .connectors_configurations = .{},
            .metrics = .{},
            .attack_modules = .{},
        };
    }

    pub fn deinit(self: *AppConfigEntity) void {
        for (self.connectors_configurations.items) |*connector| {
            connector.deinit(self.allocator);
        }
        for (self.metrics.items) |*metric| {
            metric.deinit(self.allocator);
        }
        for (self.attack_modules.items) |*module| {
            module.deinit(self.allocator);
        }
        self.connectors_configurations.deinit(self.allocator);
        self.metrics.deinit(self.allocator);
        self.attack_modules.deinit(self.allocator);
    }

    pub fn fromJsonText(allocator: std.mem.Allocator, json_text: []const u8) !AppConfigEntity {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        defer parsed.deinit();
        return try fromJsonValue(allocator, parsed.value);
    }

    pub fn fromJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !AppConfigEntity {
        if (value != .object) return EntityError.InvalidJsonRoot;

        var config = AppConfigEntity.init(allocator);
        errdefer config.deinit();

        const root = value.object;

        if (root.get("common")) |common_value| {
            if (common_value != .object) return EntityError.InvalidJsonField;
            const common_obj = common_value.object;
            config.common.max_concurrency = parseI64(common_obj.get("max_concurrency"), config.common.max_concurrency);
            config.common.max_calls_per_minute = parseI64(common_obj.get("max_calls_per_minute"), config.common.max_calls_per_minute);
            config.common.max_attempts = parseI64(common_obj.get("max_attempts"), config.common.max_attempts);
        }

        if (root.get("connectors_configurations")) |connectors_value| {
            if (connectors_value != .array) return EntityError.InvalidJsonField;
            for (connectors_value.array.items) |item| {
                if (item != .object) continue;
                const obj = item.object;
                try config.connectors_configurations.append(allocator, .{
                    .name = try dupObjectStringOrDefault(allocator, obj, "name", ""),
                    .connector_adapter = try dupObjectStringOrDefault(allocator, obj, "connector_adapter", ""),
                    .model = try dupObjectStringOrDefault(allocator, obj, "model", ""),
                    .model_endpoint = try dupObjectStringOrDefault(allocator, obj, "model_endpoint", ""),
                    .params_json = try dupObjectJsonOrDefault(allocator, obj, "params", "{}"),
                    .connector_pre_prompt = try dupObjectStringOrDefault(allocator, obj, "connector_pre_prompt", ""),
                    .connector_post_prompt = try dupObjectStringOrDefault(allocator, obj, "connector_post_prompt", ""),
                    .system_prompt = try dupObjectStringOrDefault(allocator, obj, "system_prompt", ""),
                });
            }
        }

        if (root.get("metrics")) |metrics_value| {
            if (metrics_value != .array) return EntityError.InvalidJsonField;
            for (metrics_value.array.items) |item| {
                if (item != .object) continue;
                try config.metrics.append(allocator, .{
                    .name = try dupObjectStringOrDefault(allocator, item.object, "name", ""),
                });
            }
        }

        if (root.get("attack_modules")) |attack_modules_value| {
            if (attack_modules_value != .array) return EntityError.InvalidJsonField;
            for (attack_modules_value.array.items) |item| {
                if (item != .object) continue;
                try config.attack_modules.append(allocator, .{
                    .name = try dupObjectStringOrDefault(allocator, item.object, "name", ""),
                });
            }
        }

        return config;
    }

    pub fn connectorByName(self: *const AppConfigEntity, name: []const u8) ?*const ConnectorEntity {
        for (self.connectors_configurations.items) |*connector| {
            if (std.mem.eql(u8, connector.name, name)) return connector;
        }
        return null;
    }
};

fn parseI64(maybe_value: ?std.json.Value, default_value: i64) i64 {
    const value = maybe_value orelse return default_value;
    return switch (value) {
        .integer => |v| v,
        .float => |v| @as(i64, @intFromFloat(v)),
        else => default_value,
    };
}

fn dupObjectStringOrDefault(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
    default_value: []const u8,
) ![]u8 {
    if (object.get(key)) |value| {
        if (value == .string) return allocator.dupe(u8, value.string);
    }
    return allocator.dupe(u8, default_value);
}

fn dupObjectJsonOrDefault(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
    default_value: []const u8,
) ![]u8 {
    if (object.get(key)) |value| {
        if (value == .object) {
            return std.json.Stringify.valueAlloc(allocator, value, .{});
        }
    }
    return allocator.dupe(u8, default_value);
}

test "app config parses core fields" {
    const json_text =
        \\{
        \\  "common": {
        \\    "max_concurrency": 9,
        \\    "max_calls_per_minute": 120,
        \\    "max_attempts": 4
        \\  },
        \\  "connectors_configurations": [
        \\    {
        \\      "name": "my-gpt-4o",
        \\      "connector_adapter": "openai_adapter",
        \\      "model": "gpt-4o",
        \\      "params": { "temperature": 0.2 }
        \\    }
        \\  ],
        \\  "metrics": [
        \\    { "name": "accuracy_adapter" }
        \\  ],
        \\  "attack_modules": [
        \\    { "name": "hallucination" }
        \\  ]
        \\}
    ;

    var config = try AppConfigEntity.fromJsonText(std.testing.allocator, json_text);
    defer config.deinit();

    try std.testing.expectEqual(@as(i64, 9), config.common.max_concurrency);
    try std.testing.expectEqual(@as(i64, 120), config.common.max_calls_per_minute);
    try std.testing.expectEqual(@as(i64, 4), config.common.max_attempts);
    try std.testing.expectEqual(@as(usize, 1), config.connectors_configurations.items.len);
    try std.testing.expectEqual(@as(usize, 1), config.metrics.items.len);
    try std.testing.expectEqual(@as(usize, 1), config.attack_modules.items.len);
    try std.testing.expect(config.connectorByName("my-gpt-4o") != null);
    try std.testing.expectEqualStrings(
        "{\"temperature\":0.2}",
        config.connectors_configurations.items[0].params_json,
    );
}

test "app config uses defaults when common is missing" {
    const json_text =
        \\{
        \\  "connectors_configurations": [],
        \\  "metrics": [],
        \\  "attack_modules": []
        \\}
    ;

    var config = try AppConfigEntity.fromJsonText(std.testing.allocator, json_text);
    defer config.deinit();

    try std.testing.expectEqual(@as(i64, 5), config.common.max_concurrency);
    try std.testing.expectEqual(@as(i64, 60), config.common.max_calls_per_minute);
    try std.testing.expectEqual(@as(i64, 3), config.common.max_attempts);
}
