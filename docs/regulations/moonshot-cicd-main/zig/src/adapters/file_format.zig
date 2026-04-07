const std = @import("std");

pub const JsonAdapter = struct {
    pub const SUFFIX = ".json";

    pub fn supports(path: []const u8) bool {
        return std.mem.endsWith(u8, path, SUFFIX);
    }

    pub fn serialize(allocator: std.mem.Allocator, value: anytype) ?[]u8 {
        return std.json.Stringify.valueAlloc(allocator, value, .{
            .whitespace = .indent_2,
        }) catch null;
    }

    pub fn deserialize(allocator: std.mem.Allocator, content: []const u8) ?std.json.Parsed(std.json.Value) {
        return std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch null;
    }
};

pub const YamlScalar = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    null,
    unsupported_set,
};

pub const YamlPair = struct {
    key: []const u8,
    value: YamlScalar,
};

pub const YamlParsedPair = struct {
    key: []u8,
    value: YamlScalar,

    pub fn deinit(self: *YamlParsedPair, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        switch (self.value) {
            .string => |v| allocator.free(v),
            else => {},
        }
    }
};

pub const YamlDocument = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(YamlParsedPair),

    pub fn init(allocator: std.mem.Allocator) YamlDocument {
        return .{
            .allocator = allocator,
            .items = .{},
        };
    }

    pub fn deinit(self: *YamlDocument) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }
};

pub const YamlAdapter = struct {
    pub const SUFFIX = ".yaml";

    pub fn supports(path: []const u8) bool {
        return std.mem.endsWith(u8, path, SUFFIX);
    }

    pub fn serialize(allocator: std.mem.Allocator, pairs: []const YamlPair) ?[]u8 {
        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(allocator);

        for (pairs) |pair| {
            if (pair.value == .unsupported_set) return null;
            out.appendSlice(allocator, pair.key) catch return null;
            out.appendSlice(allocator, ": ") catch return null;
            appendScalar(&out, allocator, pair.value) catch return null;
            out.append(allocator, '\n') catch return null;
        }

        return out.toOwnedSlice(allocator) catch null;
    }

    pub fn deserialize(allocator: std.mem.Allocator, content: []const u8) ?YamlDocument {
        var doc = YamlDocument.init(allocator);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;

            const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse {
                doc.deinit();
                return null;
            };
            if (colon_idx == 0) {
                doc.deinit();
                return null;
            }

            const key_trim = std.mem.trim(u8, line[0..colon_idx], " \t\r");
            if (key_trim.len == 0) {
                doc.deinit();
                return null;
            }
            const value_trim = std.mem.trim(u8, line[colon_idx + 1 ..], " \t\r");

            const key = allocator.dupe(u8, key_trim) catch {
                doc.deinit();
                return null;
            };

            const scalar = parseScalar(allocator, value_trim) catch {
                allocator.free(key);
                doc.deinit();
                return null;
            };

            doc.items.append(allocator, .{
                .key = key,
                .value = scalar,
            }) catch {
                allocator.free(key);
                switch (scalar) {
                    .string => |v| allocator.free(v),
                    else => {},
                }
                doc.deinit();
                return null;
            };
        }

        return doc;
    }

    fn appendScalar(
        out: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,
        scalar: YamlScalar,
    ) !void {
        switch (scalar) {
            .string => |v| try out.appendSlice(allocator, v),
            .integer => |v| try out.writer(allocator).print("{d}", .{v}),
            .float => |v| try out.writer(allocator).print("{d}", .{v}),
            .boolean => |v| try out.appendSlice(allocator, if (v) "true" else "false"),
            .null => try out.appendSlice(allocator, "null"),
            .unsupported_set => return error.UnsupportedScalar,
        }
    }

    fn parseScalar(allocator: std.mem.Allocator, raw: []const u8) !YamlScalar {
        if (raw.len == 0) return .null;
        if (std.ascii.eqlIgnoreCase(raw, "null")) return .null;
        if (std.ascii.eqlIgnoreCase(raw, "true")) return .{ .boolean = true };
        if (std.ascii.eqlIgnoreCase(raw, "false")) return .{ .boolean = false };

        if (std.fmt.parseInt(i64, raw, 10)) |v| {
            return .{ .integer = v };
        } else |_| {}

        if (std.fmt.parseFloat(f64, raw)) |v| {
            return .{ .float = v };
        } else |_| {}

        if (raw.len >= 2 and ((raw[0] == '"' and raw[raw.len - 1] == '"') or (raw[0] == '\'' and raw[raw.len - 1] == '\''))) {
            return .{ .string = try allocator.dupe(u8, raw[1 .. raw.len - 1]) };
        }

        return .{ .string = try allocator.dupe(u8, raw) };
    }
};

fn runPython(allocator: std.mem.Allocator, code: []const u8, args: []const []const u8) ![]u8 {
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

fn jsonValueToI64(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        else => null,
    };
}

test "json adapter parity serialize against python" {
    const allocator = std.testing.allocator;
    const input = "{\"key\":\"value\"}";
    const py = try runPython(
        allocator,
        "import json,sys; d=json.loads(sys.argv[1]); sys.stdout.write(json.dumps(d, indent=2, ensure_ascii=False))",
        &.{input},
    );
    defer allocator.free(py);

    var parsed = (JsonAdapter.deserialize(allocator, input) orelse return error.ParseFailed);
    defer parsed.deinit();

    const zig = JsonAdapter.serialize(allocator, parsed.value) orelse return error.SerializeFailed;
    defer allocator.free(zig);
    try std.testing.expectEqualStrings(py, zig);
}

test "json adapter parity deserialize against python" {
    const allocator = std.testing.allocator;
    const input = "{\"number\":123}";

    var parsed = (JsonAdapter.deserialize(allocator, input) orelse return error.ParseFailed);
    defer parsed.deinit();
    const number_val = parsed.value.object.get("number") orelse return error.MissingField;
    try std.testing.expectEqual(@as(i64, 123), jsonValueToI64(number_val).?);

    const py = try runPython(
        allocator,
        "import json,sys; d=json.loads(sys.argv[1]); sys.stdout.write(str(d['number']))",
        &.{input},
    );
    defer allocator.free(py);
    try std.testing.expectEqualStrings("123", py);
}

test "json adapter invalid deserialize returns null" {
    const allocator = std.testing.allocator;
    const invalid = "{\"key\":\"value\"";
    try std.testing.expect(JsonAdapter.deserialize(allocator, invalid) == null);
}

test "yaml adapter parity serialize simple map against python" {
    const allocator = std.testing.allocator;

    const pairs = [_]YamlPair{
        .{ .key = "key", .value = .{ .string = "value" } },
        .{ .key = "number", .value = .{ .integer = 123 } },
    };

    const zig = YamlAdapter.serialize(allocator, &pairs) orelse return error.SerializeFailed;
    defer allocator.free(zig);

    const py = try runPython(
        allocator,
        "import json,sys,yaml; d=json.loads(sys.argv[1]); sys.stdout.write(yaml.dump(d, default_flow_style=False))",
        &.{"{\"key\":\"value\",\"number\":123}"},
    );
    defer allocator.free(py);

    try std.testing.expectEqualStrings(py, zig);
}

test "yaml adapter serialize rejects unsupported set marker" {
    const allocator = std.testing.allocator;
    const pairs = [_]YamlPair{
        .{ .key = "key", .value = .unsupported_set },
    };
    try std.testing.expect(YamlAdapter.serialize(allocator, &pairs) == null);
}

test "yaml adapter parity deserialize against python" {
    const allocator = std.testing.allocator;
    const content = "key: value\nnumber: 123\n";
    var doc = YamlAdapter.deserialize(allocator, content) orelse return error.ParseFailed;
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc.items.items.len);

    try std.testing.expectEqualStrings("key", doc.items.items[0].key);
    try std.testing.expect(doc.items.items[0].value == .string);
    try std.testing.expectEqualStrings("value", doc.items.items[0].value.string);
    try std.testing.expect(doc.items.items[1].value == .integer);
    try std.testing.expectEqual(@as(i64, 123), doc.items.items[1].value.integer);

    const py = try runPython(
        allocator,
        "import sys,yaml; d=yaml.safe_load(sys.argv[1]); sys.stdout.write(d['key'] + '|' + str(d['number']))",
        &.{content},
    );
    defer allocator.free(py);
    try std.testing.expectEqualStrings("value|123", py);
}

test "yaml adapter invalid deserialize returns null" {
    const allocator = std.testing.allocator;
    const invalid = "key: value\nnumber: 123\ninvalid_yaml";
    try std.testing.expect(YamlAdapter.deserialize(allocator, invalid) == null);
}

test "supports helpers parity" {
    try std.testing.expect(JsonAdapter.supports("file.json"));
    try std.testing.expect(!JsonAdapter.supports("file.txt"));
    try std.testing.expect(YamlAdapter.supports("file.yaml"));
    try std.testing.expect(!YamlAdapter.supports("file.txt"));
}
