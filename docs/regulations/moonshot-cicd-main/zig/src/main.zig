const std = @import("std");
const metadata_mod = @import("runtime/metadata.zig");
const config_loader = @import("runtime/config_loader.zig");
const app_config_runtime = @import("runtime/app_config.zig");
const TaskManager = @import("domain/services/task_manager.zig").TaskManager;
const TaskManagerError = @import("domain/services/task_manager.zig").TaskManagerError;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const project_root = try findProjectRoot(allocator);
    defer allocator.free(project_root);

    var metadata: metadata_mod.Metadata = metadata_mod.loadMetadata(allocator, project_root) catch blk: {
        break :blk .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, "moonshot-cicd"),
            .version = try allocator.dupe(u8, "unknown"),
            .author = try allocator.dupe(u8, "unknown"),
            .license = try allocator.dupe(u8, "Apache-2.0"),
            .description = try allocator.dupe(u8, "Moonshot Zig compatibility runtime"),
        };
    };
    defer metadata.deinit();

    const all_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, all_args);

    if (all_args.len <= 1) {
        printBanner(metadata);
        printUsage(all_args[0]);
        return;
    }

    const first = all_args[1];
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "help")) {
        printBanner(metadata);
        printUsage(all_args[0]);
        return;
    }

    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "version")) {
        std.debug.print("{s} {s}\n", .{ metadata.name, metadata.version });
        return;
    }

    if (std.mem.eql(u8, first, "run")) {
        if (all_args.len < 5) {
            std.debug.print(
                "[moonshot-zig] missing required arguments: run <run_id> <test_config_id> <connector>\n",
                .{},
            );
            printUsage(all_args[0]);
            std.process.exit(2);
        }

        const run_id = all_args[2];
        const test_config_id = all_args[3];
        const connector_name = all_args[4];

        var app_config = app_config_runtime.AppConfig.load(
            allocator,
            project_root,
        ) catch |err| {
            std.debug.print(
                "[moonshot-zig] failed to load app config: {s}\n",
                .{@errorName(err)},
            );
            std.process.exit(1);
        };
        defer app_config.deinit();

        var manager = TaskManager.init(
            allocator,
            &app_config,
            project_root,
        );
        var summary = manager.runTest(run_id, test_config_id, connector_name) catch |err| {
            printRunFailure(err, test_config_id, connector_name);
            std.process.exit(1);
        };
        defer summary.deinit(allocator);

        const output = .{
            .status = "success",
            .run_id = summary.run_id,
            .test_config_id = summary.test_config_id,
            .connector = summary.connector,
            .result_path = summary.result_path,
            .tests_executed = summary.tests_executed,
            .dry_run_prompts = summary.dry_run_prompts,
            .duration_seconds = summary.duration_seconds,
        };
        const output_json = std.json.Stringify.valueAlloc(allocator, output, .{}) catch {
            std.debug.print(
                "{{\"status\":\"success\",\"run_id\":\"{s}\",\"result_path\":\"{s}\"}}\n",
                .{ summary.run_id, summary.result_path },
            );
            return;
        };
        defer allocator.free(output_json);
        std.debug.print("{s}\n", .{output_json});
        return;
    }

    if (std.mem.eql(u8, first, "zig-config")) {
        const config_path = getenvOrDefault(
            app_config_runtime.AppConfig.CONFIG_PATH_ENV_VAR,
            app_config_runtime.AppConfig.DEFAULT_CONFIG_PATH,
        );
        var config = try config_loader.loadFromConfigPath(
            allocator,
            project_root,
            config_path,
        );
        defer config.deinit();

        std.debug.print("Config summary\n", .{});
        std.debug.print("  max_concurrency: {d}\n", .{config.common.max_concurrency});
        std.debug.print("  max_calls_per_minute: {d}\n", .{config.common.max_calls_per_minute});
        std.debug.print("  max_attempts: {d}\n", .{config.common.max_attempts});
        std.debug.print("  connectors: {d}\n", .{config.connectors_configurations.items.len});
        std.debug.print("  metrics: {d}\n", .{config.metrics.items.len});
        std.debug.print("  attack_modules: {d}\n", .{config.attack_modules.items.len});
        return;
    }

    std.debug.print(
        "[moonshot-zig] unsupported command '{s}'. Supported commands: run, zig-config, --help, --version.\n",
        .{first},
    );
    printUsage(all_args[0]);
    std.process.exit(2);
}

fn printBanner(metadata: metadata_mod.Metadata) void {
    std.debug.print("Project Moonshot (Zig compatibility runtime)\n", .{});
    std.debug.print("Name: {s}\n", .{metadata.name});
    std.debug.print("Version: {s}\n", .{metadata.version});
    std.debug.print("Author: {s}\n", .{metadata.author});
    std.debug.print("License: {s}\n", .{metadata.license});
    std.debug.print("Description: {s}\n\n", .{metadata.description});
}

fn printUsage(argv0: []const u8) void {
    std.debug.print("Usage:\n", .{});
    std.debug.print("  {s} run <run_id> <test_config_id> <connector>\n", .{argv0});
    std.debug.print("  {s} zig-config\n", .{argv0});
    std.debug.print("  {s} --version\n", .{argv0});
    std.debug.print("\n", .{});
    std.debug.print(
        "The `run` command executes natively in Zig. Legacy Python command forwarding has been removed.\n",
        .{},
    );
}

fn printRunFailure(err: anyerror, test_config_id: []const u8, connector_name: []const u8) void {
    switch (err) {
        TaskManagerError.TestConfigNotFound => std.debug.print(
            "[moonshot-zig] test config '{s}' was not found in the test configuration file.\n",
            .{test_config_id},
        ),
        TaskManagerError.ConnectorNotFound => std.debug.print(
            "[moonshot-zig] connector '{s}' was not found in moonshot_config.yaml.\n",
            .{connector_name},
        ),
        TaskManagerError.MetricNotFound => std.debug.print(
            "[moonshot-zig] metric configuration referenced by this test was not found.\n",
            .{},
        ),
        TaskManagerError.DatasetLoadFailed => std.debug.print(
            "[moonshot-zig] dataset file could not be opened. Verify data/datasets and dataset names in tests config.\n",
            .{},
        ),
        TaskManagerError.InvalidDataset => std.debug.print(
            "[moonshot-zig] dataset format is invalid. Supported shapes: top-level array or object with an `examples` array.\n",
            .{},
        ),
        TaskManagerError.ResultWriteFailed => std.debug.print(
            "[moonshot-zig] run completed but writing the result file failed (data/results/<run_id>.json).\n",
            .{},
        ),
        TaskManagerError.ResultSerializationFailed => std.debug.print(
            "[moonshot-zig] run completed but serializing the result payload failed.\n",
            .{},
        ),
        else => std.debug.print(
            "[moonshot-zig] run failed: {s}\n",
            .{@errorName(err)},
        ),
    }
}

fn getenvOrDefault(name: []const u8, default_value: []const u8) []const u8 {
    const maybe_value = std.posix.getenv(name);
    return if (maybe_value) |value| value else default_value;
}

fn findProjectRoot(allocator: std.mem.Allocator) ![]u8 {
    var current = try std.fs.cwd().realpathAlloc(allocator, ".");
    errdefer allocator.free(current);

    var depth: usize = 0;
    while (depth < 12) : (depth += 1) {
        if (try isMoonshotProjectRoot(allocator, current)) {
            return current;
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    return error.ProjectRootNotFound;
}

fn isMoonshotProjectRoot(allocator: std.mem.Allocator, candidate: []const u8) !bool {
    const pyproject = try std.fs.path.join(allocator, &.{ candidate, "pyproject.toml" });
    defer allocator.free(pyproject);
    const main_file = try std.fs.path.join(allocator, &.{ candidate, "__main__.py" });
    defer allocator.free(main_file);
    return pathExists(pyproject) and pathExists(main_file);
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

test "find root helper from current directory returns a path" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const path = findProjectRoot(allocator) catch return;
    defer allocator.free(path);
    try std.testing.expect(path.len > 0);
}
