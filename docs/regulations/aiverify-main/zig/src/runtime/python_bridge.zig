const std = @import("std");

pub const BridgeOptions = struct {
    allocator: std.mem.Allocator,
    project_root: []const u8,
    python_executable: []const u8,
    component_cwd: []const u8,
    python_module: []const u8,
    pythonpath: ?[]const u8 = null,
    forward_args: []const []const u8,
};

pub fn run(options: BridgeOptions) !u8 {
    const component_root = try std.fs.path.join(options.allocator, &.{
        options.project_root,
        options.component_cwd,
    });
    defer options.allocator.free(component_root);

    var argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer argv.deinit(options.allocator);

    try argv.append(options.allocator, options.python_executable);
    try argv.append(options.allocator, "-m");
    try argv.append(options.allocator, options.python_module);
    for (options.forward_args) |arg| {
        try argv.append(options.allocator, arg);
    }

    var child = std.process.Child.init(argv.items, options.allocator);
    child.cwd = component_root;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    if (options.pythonpath) |pythonpath_rel| {
        var env_map = try std.process.getEnvMap(options.allocator);
        defer env_map.deinit();

        const pythonpath_abs = try std.fs.path.join(options.allocator, &.{
            options.project_root,
            pythonpath_rel,
        });
        defer options.allocator.free(pythonpath_abs);

        const merged_pythonpath = try mergePythonPath(options.allocator, &env_map, pythonpath_abs);
        defer options.allocator.free(merged_pythonpath);
        try env_map.put("PYTHONPATH", merged_pythonpath);

        child.env_map = &env_map;
        const term = try child.spawnAndWait();
        return terminationToExitCode(term);
    }

    const term = try child.spawnAndWait();
    return terminationToExitCode(term);
}

fn terminationToExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn mergePythonPath(
    allocator: std.mem.Allocator,
    env_map: *std.process.EnvMap,
    new_path: []const u8,
) ![]u8 {
    if (env_map.get("PYTHONPATH")) |existing| {
        if (existing.len == 0) {
            return allocator.dupe(u8, new_path);
        }
        return std.fmt.allocPrint(
            allocator,
            "{s}{c}{s}",
            .{ new_path, std.fs.path.delimiter, existing },
        );
    }
    return allocator.dupe(u8, new_path);
}

test "mergePythonPath prepends new path when existing value is present" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("PYTHONPATH", "/existing/path");

    const merged = try mergePythonPath(std.testing.allocator, &env_map, "/new/path");
    defer std.testing.allocator.free(merged);

    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "/new/path{c}/existing/path",
        .{std.fs.path.delimiter},
    );
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, merged);
}

test "mergePythonPath returns new path when existing value is absent" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    const merged = try mergePythonPath(std.testing.allocator, &env_map, "/new/path");
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqualStrings("/new/path", merged);
}
