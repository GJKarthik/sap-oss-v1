const std = @import("std");

pub const Metadata = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    version: []u8,
    author: []u8,
    license: []u8,
    description: []u8,

    pub fn deinit(self: *Metadata) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        self.allocator.free(self.author);
        self.allocator.free(self.license);
        self.allocator.free(self.description);
    }
};

pub fn loadMetadata(allocator: std.mem.Allocator, project_root: []const u8) !Metadata {
    const pyproject_path = try std.fs.path.join(allocator, &.{
        project_root,
        "aiverify-apigw/pyproject.toml",
    });
    defer allocator.free(pyproject_path);

    const source = try std.fs.cwd().readFileAlloc(allocator, pyproject_path, 2 * 1024 * 1024);
    defer allocator.free(source);

    var name: []const u8 = "aiverify";
    var version: []const u8 = "unknown";
    var author: []const u8 = "AI Verify Foundation";
    var license: []const u8 = "MIT";
    var description: []const u8 = "AI Verify Zig compatibility runtime";

    var in_project_section = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            in_project_section = std.mem.eql(u8, line, "[project]");
            continue;
        }
        if (!in_project_section) continue;

        if (extractTomlString(line, "name")) |value| {
            name = value;
            continue;
        }
        if (extractTomlString(line, "version")) |value| {
            version = value;
            continue;
        }
        if (extractTomlString(line, "license")) |value| {
            license = value;
            continue;
        }
        if (extractTomlString(line, "description")) |value| {
            description = value;
            continue;
        }
        if (extractAuthorName(line)) |value| {
            author = value;
            continue;
        }
    }

    return .{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .version = try allocator.dupe(u8, version),
        .author = try allocator.dupe(u8, author),
        .license = try allocator.dupe(u8, license),
        .description = try allocator.dupe(u8, description),
    };
}

fn extractTomlString(line: []const u8, key: []const u8) ?[]const u8 {
    var prefix_buf: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{s} = \"", .{key}) catch return null;
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    if (line.len <= prefix.len + 1) return null;
    if (line[line.len - 1] != '"') return null;
    return line[prefix.len .. line.len - 1];
}

fn extractAuthorName(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "authors = [")) return null;
    const key = "name = \"";
    const start_idx = std.mem.indexOf(u8, line, key) orelse return null;
    const value_start = start_idx + key.len;
    const value_end = std.mem.indexOfScalarPos(u8, line, value_start, '"') orelse return null;
    if (value_end <= value_start) return null;
    return line[value_start..value_end];
}

test "extract helpers parse project metadata lines" {
    try std.testing.expectEqualStrings(
        "aiverify-apigw",
        extractTomlString("name = \"aiverify-apigw\"", "name").?,
    );
    try std.testing.expect(extractTomlString("name=aiverify", "name") == null);
    try std.testing.expectEqualStrings(
        "Peck Yoke",
        extractAuthorName("authors = [{ name = \"Peck Yoke\", email = \"foo@example.com\" }]").?,
    );
}
