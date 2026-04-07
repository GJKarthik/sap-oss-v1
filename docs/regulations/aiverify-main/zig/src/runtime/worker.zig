const std = @import("std");

pub const WorkerConfigError = error{
    InvalidValkeyPort,
    MissingPipelineModule,
    DataDirUnavailable,
    OutOfMemory,
};

pub const TASK_STREAM_NAME = "aiverify:worker:task_queue";
pub const TASK_GROUP_NAME = "aiverify_workers";
pub const WORKER_BLOCK_MS: u32 = 3000;
pub const WORKER_RECLAIM_IDLE_MS: u32 = 60_000;
pub const WORKER_RECLAIM_START_ID = "0-0";

pub const WorkerAction = enum {
    config,
    once,
    pass_through,
};

pub const WorkerInvocation = struct {
    action: WorkerAction,
    ack: bool = false,
    reclaim: bool = false,
    reclaim_min_idle_ms: u32 = WORKER_RECLAIM_IDLE_MS,
    reclaim_start: []const u8 = WORKER_RECLAIM_START_ID,
};

pub const WorkerConfig = struct {
    data_dir: []u8,
    log_level: ?[]const u8,
    apigw_url: []const u8,
    valkey_host: []const u8,
    valkey_port: u16,
    python_bin: []const u8,
    pipeline_download: []const u8,
    pipeline_build: []const u8,
    pipeline_validate_input: []const u8,
    pipeline_execute: []const u8,
    pipeline_upload: []const u8,
    pipeline_error: []const u8,
    docker_registry: ?[]const u8,
    kubectl_registry: []const u8,

    pub fn deinit(self: *WorkerConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.data_dir);
    }
};

pub fn classifyArgs(args: []const []const u8) WorkerAction {
    return classifyInvocation(args).action;
}

pub fn classifyInvocation(args: []const []const u8) WorkerInvocation {
    if (args.len == 1) {
        const arg = args[0];
        if (std.mem.eql(u8, arg, "config") or
            std.mem.eql(u8, arg, "--config") or
            std.mem.eql(u8, arg, "preflight") or
            std.mem.eql(u8, arg, "--preflight"))
        {
            return .{ .action = .config };
        }
        if (std.mem.eql(u8, arg, "once") or std.mem.eql(u8, arg, "--once")) {
            return .{ .action = .once };
        }
    }
    if (args.len > 1 and (std.mem.eql(u8, args[0], "once") or std.mem.eql(u8, args[0], "--once"))) {
        return parseOnceOptions(args[1..]);
    }
    return .{ .action = .pass_through };
}

pub fn classifyOnceArgs(args: []const []const u8) WorkerInvocation {
    return parseOnceOptions(args);
}

pub fn loadConfig(
    allocator: std.mem.Allocator,
    project_root: []const u8,
) !WorkerConfig {
    const data_dir = if (std.posix.getenv("TEWORKER_DATA_DIR")) |value|
        try allocator.dupe(u8, value)
    else
        try std.fs.path.join(allocator, &.{ project_root, "aiverify-test-engine-worker", "data" });
    errdefer allocator.free(data_dir);

    std.fs.cwd().makePath(data_dir) catch return WorkerConfigError.DataDirUnavailable;

    const valkey_port = parseValkeyPort(std.posix.getenv("VALKEY_PORT") orelse "6379") catch {
        return WorkerConfigError.InvalidValkeyPort;
    };

    const docker_registry = optionalEnv("DOCKER_REGISTRY");
    const kubectl_registry = resolveKubectlRegistry(
        optionalEnv("KUBECTL_REGISTRY"),
        docker_registry,
    );

    return .{
        .data_dir = data_dir,
        .log_level = optionalEnv("TEWORKER_LOG_LEVEL"),
        .apigw_url = std.posix.getenv("APIGW_URL") orelse "http://127.0.0.1:4000",
        .valkey_host = std.posix.getenv("VALKEY_HOST_ADDRESS") orelse "127.0.0.1",
        .valkey_port = valkey_port,
        .python_bin = std.posix.getenv("PYTHON") orelse "python3",
        .pipeline_download = std.posix.getenv("PIPELINE_DOWNLOAD") orelse "apigw_download",
        .pipeline_build = std.posix.getenv("PIPELINE_BUILD") orelse "virtual_env",
        .pipeline_validate_input = std.posix.getenv("PIPELINE_VALIDATE_INPUT") orelse "validate_input",
        .pipeline_execute = std.posix.getenv("PIPELINE_EXECUTE") orelse "virtual_env_execute",
        .pipeline_upload = std.posix.getenv("PIPELINE_UPLOAD") orelse "apigw_upload",
        .pipeline_error = std.posix.getenv("pipeline_error") orelse (std.posix.getenv("PIPELINE_ERROR") orelse "apigw_error_update"),
        .docker_registry = docker_registry,
        .kubectl_registry = kubectl_registry,
    };
}

pub fn validateStartupConfig(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    config: *const WorkerConfig,
) !void {
    const pipeline_root = try std.fs.path.join(allocator, &.{
        project_root,
        "aiverify-test-engine-worker",
        "src",
        "aiverify_test_engine_worker",
        "pipeline",
    });
    defer allocator.free(pipeline_root);

    try ensureModuleExists(allocator, pipeline_root, "download", config.pipeline_download);
    try ensureModuleExists(allocator, pipeline_root, "pipeline_build", config.pipeline_build);
    try ensureModuleExists(allocator, pipeline_root, "validate_input", config.pipeline_validate_input);
    try ensureModuleExists(allocator, pipeline_root, "pipeline_execute", config.pipeline_execute);
    try ensureModuleExists(allocator, pipeline_root, "upload", config.pipeline_upload);
    try ensureModuleExists(allocator, pipeline_root, "pipeline_error", config.pipeline_error);
}

pub fn renderSummary(allocator: std.mem.Allocator, config: *const WorkerConfig) ![]u8 {
    const log_level = config.log_level orelse "<unset>";
    const docker_registry = config.docker_registry orelse "<unset>";

    return std.fmt.allocPrint(
        allocator,
        \\Worker startup preflight
        \\  data_dir: {s}
        \\  log_level: {s}
        \\  apigw_url: {s}
        \\  valkey_host: {s}
        \\  valkey_port: {d}
        \\  python_bin: {s}
        \\  pipeline_download: {s}
        \\  pipeline_build: {s}
        \\  pipeline_validate_input: {s}
        \\  pipeline_execute: {s}
        \\  pipeline_upload: {s}
        \\  pipeline_error: {s}
        \\  docker_registry: {s}
        \\  kubectl_registry: {s}
        ,
        .{
            config.data_dir,
            log_level,
            config.apigw_url,
            config.valkey_host,
            config.valkey_port,
            config.python_bin,
            config.pipeline_download,
            config.pipeline_build,
            config.pipeline_validate_input,
            config.pipeline_execute,
            config.pipeline_upload,
            config.pipeline_error,
            docker_registry,
            config.kubectl_registry,
        },
    );
}

fn ensureModuleExists(
    allocator: std.mem.Allocator,
    pipeline_root: []const u8,
    stage_dir: []const u8,
    module_name: []const u8,
) !void {
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}.py",
        .{ pipeline_root, stage_dir, module_name },
    );
    defer allocator.free(path);

    if (!pathExists(path)) {
        return WorkerConfigError.MissingPipelineModule;
    }
}

fn parseValkeyPort(raw: []const u8) !u16 {
    const value = std.fmt.parseInt(u32, raw, 10) catch return WorkerConfigError.InvalidValkeyPort;
    if (value > std.math.maxInt(u16)) return WorkerConfigError.InvalidValkeyPort;
    return @intCast(value);
}

fn optionalEnv(name: []const u8) ?[]const u8 {
    const value = std.posix.getenv(name) orelse return null;
    if (value.len == 0) return null;
    return value;
}

fn resolveKubectlRegistry(
    explicit_kubectl: ?[]const u8,
    docker_registry: ?[]const u8,
) []const u8 {
    if (explicit_kubectl) |value| return value;
    if (docker_registry) |value| return value;
    return "localhost:5000";
}

fn parseOnceOptions(args: []const []const u8) WorkerInvocation {
    var invocation: WorkerInvocation = .{ .action = .once };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const token = args[i];
        if (std.mem.eql(u8, token, "--ack")) {
            invocation.ack = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--reclaim")) {
            invocation.reclaim = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--min-idle-ms")) {
            if (i + 1 >= args.len) return .{ .action = .pass_through };
            const value = std.fmt.parseInt(u32, args[i + 1], 10) catch return .{ .action = .pass_through };
            invocation.reclaim_min_idle_ms = value;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, token, "--start")) {
            if (i + 1 >= args.len) return .{ .action = .pass_through };
            const value = args[i + 1];
            if (value.len == 0) return .{ .action = .pass_through };
            invocation.reclaim_start = value;
            i += 1;
            continue;
        }
        return .{ .action = .pass_through };
    }
    return invocation;
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

test "classifyArgs detects config/preflight variants" {
    try std.testing.expectEqual(WorkerAction.config, classifyArgs(&.{"config"}));
    try std.testing.expectEqual(WorkerAction.config, classifyArgs(&.{"--preflight"}));
    try std.testing.expectEqual(WorkerAction.once, classifyArgs(&.{"--once"}));
    try std.testing.expectEqual(WorkerAction.pass_through, classifyArgs(&.{}));
    try std.testing.expectEqual(WorkerAction.pass_through, classifyArgs(&.{"run"}));
}

test "classifyInvocation parses ack option for once mode" {
    const invocation_1 = classifyInvocation(&.{"--once"});
    try std.testing.expectEqual(WorkerAction.once, invocation_1.action);
    try std.testing.expect(!invocation_1.ack);

    const invocation_2 = classifyInvocation(&.{ "--once", "--ack", "--reclaim" });
    try std.testing.expectEqual(WorkerAction.once, invocation_2.action);
    try std.testing.expect(invocation_2.ack);
    try std.testing.expect(invocation_2.reclaim);

    const invocation_3 = classifyInvocation(&.{ "--once", "--bad-flag" });
    try std.testing.expectEqual(WorkerAction.pass_through, invocation_3.action);
}

test "classifyOnceArgs parses reclaim options" {
    const invocation = classifyOnceArgs(&.{ "--reclaim", "--min-idle-ms", "15000", "--start", "10-0", "--ack" });
    try std.testing.expectEqual(WorkerAction.once, invocation.action);
    try std.testing.expect(invocation.reclaim);
    try std.testing.expect(invocation.ack);
    try std.testing.expectEqual(@as(u32, 15_000), invocation.reclaim_min_idle_ms);
    try std.testing.expectEqualStrings("10-0", invocation.reclaim_start);
}

test "parseValkeyPort parses valid values and rejects invalid values" {
    try std.testing.expectEqual(@as(u16, 6379), try parseValkeyPort("6379"));
    try std.testing.expectError(WorkerConfigError.InvalidValkeyPort, parseValkeyPort("70000"));
    try std.testing.expectError(WorkerConfigError.InvalidValkeyPort, parseValkeyPort("abc"));
}

test "resolveKubectlRegistry applies expected precedence" {
    try std.testing.expectEqualStrings(
        "explicit",
        resolveKubectlRegistry("explicit", "docker"),
    );
    try std.testing.expectEqualStrings(
        "docker",
        resolveKubectlRegistry(null, "docker"),
    );
    try std.testing.expectEqualStrings(
        "localhost:5000",
        resolveKubectlRegistry(null, null),
    );
}
