const std = @import("std");

pub const VersionError = error{
    VersionNotFound,
    PythonVersionProbeFailed,
};

pub const CliAction = enum {
    version,
    help,
    pass_through,
};

pub fn renderVersionMessage(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    python_executable: []const u8,
) ![]u8 {
    const test_engine_root = try std.fs.path.join(allocator, &.{
        project_root,
        "aiverify-test-engine",
    });
    defer allocator.free(test_engine_root);

    const init_path = try std.fs.path.join(allocator, &.{
        test_engine_root,
        "aiverify_test_engine",
        "__init__.py",
    });
    defer allocator.free(init_path);

    const init_source = try std.fs.cwd().readFileAlloc(allocator, init_path, 1 * 1024 * 1024);
    defer allocator.free(init_source);

    const version = extractVersion(init_source) orelse return VersionError.VersionNotFound;
    const python_version = try probePythonVersion(allocator, project_root, python_executable);
    defer allocator.free(python_version);

    return std.fmt.allocPrint(
        allocator,
        "Test Engine Core - {s} from {s} (Python {s})",
        .{ version, test_engine_root, python_version },
    );
}

pub fn classifyArgs(args: []const []const u8) CliAction {
    if (args.len == 0) return .version;
    if (args.len == 1) {
        const arg = args[0];
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "version")) {
            return .version;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help")) {
            return .help;
        }
    }
    return .pass_through;
}

pub fn helpText() []const u8 {
    return
        \\Usage:
        \\  aiverify-zig test-engine
        \\  aiverify-zig test-engine --version
        \\  aiverify-zig test-engine --help
        \\
        \\Unsupported args are forwarded to Python module `aiverify_test_engine`.
    ;
}

fn extractVersion(source: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (extractQuotedAssignment(line, "__version__")) |value| {
            return value;
        }
    }
    return null;
}

fn extractQuotedAssignment(line: []const u8, key: []const u8) ?[]const u8 {
    var prefix_buf: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{s} = \"", .{key}) catch return null;
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    if (line.len <= prefix.len + 1) return null;
    if (line[line.len - 1] != '"') return null;
    return line[prefix.len .. line.len - 1];
}

fn probePythonVersion(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    python_executable: []const u8,
) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            python_executable,
            "-c",
            "import sys; print(sys.version, end='')",
        },
        .cwd = project_root,
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        allocator.free(result.stdout);
        return VersionError.PythonVersionProbeFailed;
    }

    return result.stdout;
}

test "extractVersion parses __version__ constant" {
    const source =
        \\Main package for Test Engine Core.
        \\
        \\__version__ = "0.9.0"
    ;
    const version = extractVersion(source).?;
    try std.testing.expectEqualStrings("0.9.0", version);
}

test "extractQuotedAssignment rejects malformed lines" {
    try std.testing.expect(extractQuotedAssignment("__version__=0.9.0", "__version__") == null);
    try std.testing.expect(extractQuotedAssignment("__version__ = \"0.9.0\"", "__version__") != null);
}

test "classifyArgs handles version, help and fallback modes" {
    try std.testing.expectEqual(CliAction.version, classifyArgs(&.{}));
    try std.testing.expectEqual(CliAction.version, classifyArgs(&.{"--version"}));
    try std.testing.expectEqual(CliAction.version, classifyArgs(&.{"version"}));
    try std.testing.expectEqual(CliAction.help, classifyArgs(&.{"--help"}));
    try std.testing.expectEqual(CliAction.help, classifyArgs(&.{"help"}));
    try std.testing.expectEqual(CliAction.pass_through, classifyArgs(&.{"--unknown"}));
    try std.testing.expectEqual(CliAction.pass_through, classifyArgs(&.{ "--foo", "bar" }));
}
