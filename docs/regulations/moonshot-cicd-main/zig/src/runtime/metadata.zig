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

pub fn loadMetadata(
    allocator: std.mem.Allocator,
    project_root: []const u8,
) !Metadata {
    const pyproject_path = try std.fs.path.join(allocator, &.{ project_root, "pyproject.toml" });
    defer allocator.free(pyproject_path);

    const source = try std.fs.cwd().readFileAlloc(allocator, pyproject_path, 2 * 1024 * 1024);
    defer allocator.free(source);

    var name: []const u8 = "moonshot-cicd";
    var version: []const u8 = "unknown";
    var author: []const u8 = "unknown";
    var license: []const u8 = "Apache-2.0";
    var description: []const u8 = "Moonshot Zig compatibility runtime";

    var in_poetry_section = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            in_poetry_section = std.mem.eql(u8, line, "[tool.poetry]");
            continue;
        }
        if (!in_poetry_section) continue;

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
        if (extractTomlArrayFirstString(line, "authors")) |value| {
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

fn extractTomlArrayFirstString(line: []const u8, key: []const u8) ?[]const u8 {
    var prefix_buf: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{s} = [", .{key}) catch return null;
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const first_quote = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const second_quote = std.mem.indexOfScalarPos(u8, line, first_quote + 1, '"') orelse return null;
    if (second_quote <= first_quote + 1) return null;
    return line[first_quote + 1 .. second_quote];
}

test "parse metadata line helpers" {
    try std.testing.expectEqualStrings(
        "moonshot-cicd",
        extractTomlString("name = \"moonshot-cicd\"", "name").?,
    );
    try std.testing.expect(extractTomlString("name=moonshot", "name") == null);
    try std.testing.expectEqualStrings(
        "Moonshot Team <team@example.com>",
        extractTomlArrayFirstString("authors = [\"Moonshot Team <team@example.com>\"]", "authors").?,
    );
}
