const std = @import("std");
const AppConfig = @import("runtime/app_config.zig").AppConfig;
const TaskManager = @import("domain/services/task_manager.zig").TaskManager;
const TaskManagerError = @import("domain/services/task_manager.zig").TaskManagerError;

test "TaskManager executes benchmark from config" {
    const config_json =
        \\{
        \\  "connectors_configurations": [
        \\    { "name": "my-gpt-4", "connector_adapter": "openai", "model": "gpt-4" }
        \\  ],
        \\  "metrics": [
        \\    { "name": "refusal", "connector_configurations": { "name": "llm", "connector_adapter": "openai", "model": "gpt-4" } }
        \\  ]
        \\}
    ;
    var app_config = try AppConfig.fromJsonText(std.testing.allocator, config_json);
    defer app_config.deinit();

    var tm = TaskManager.init(std.testing.allocator, &app_config, ".");

    const test_config_json =
        \\{
        \\  "test_1": [
        \\    {
        \\      "name": "benchmark_1",
        \\      "type": "benchmark",
        \\      "dataset": "dataset_1",
        \\      "metric": "refusal"
        \\    }
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, test_config_json, .{});
    defer parsed.deinit();

    try tm.executeTestConfig("run_1", "test_1", "my-gpt-4", parsed.value.object);
}

test "TaskManager fails on missing connector" {
    const config_json =
        \\{
        \\  "connectors_configurations": [],
        \\  "metrics": []
        \\}
    ;
    var app_config = try AppConfig.fromJsonText(std.testing.allocator, config_json);
    defer app_config.deinit();

    var tm = TaskManager.init(std.testing.allocator, &app_config, ".");

    const test_config_json =
        \\{
        \\  "test_1": [
        \\    { "name": "benchmark_1", "type": "benchmark", "dataset": "d1", "metric": "m1" }
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, test_config_json, .{});
    defer parsed.deinit();

    try std.testing.expectError(
        TaskManagerError.ConnectorNotFound,
        tm.executeTestConfig("run_1", "test_1", "missing-connector", parsed.value.object)
    );
}

test "TaskManager executes scan from config" {
    const config_json =
        \\{
        \\  "connectors_configurations": [
        \\    { "name": "my-gpt-4", "connector_adapter": "openai", "model": "gpt-4" }
        \\  ],
        \\  "attack_modules": [
        \\    { "name": "jailbreak", "connector_configurations": { "prompt_llm": { "connector_adapter": "openai", "model": "gpt-4" } } }
        \\  ]
        \\}
    ;
    var app_config = try AppConfig.fromJsonText(std.testing.allocator, config_json);
    defer app_config.deinit();

    var tm = TaskManager.init(std.testing.allocator, &app_config, ".");

    const test_config_json =
        \\{
        \\  "test_scan": [
        \\    {
        \\      "name": "scan_1",
        \\      "type": "scan",
        \\      "attack_module": "jailbreak"
        \\    }
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, test_config_json, .{});
    defer parsed.deinit();

    try tm.executeTestConfig("run_scan", "test_scan", "my-gpt-4", parsed.value.object);
}
