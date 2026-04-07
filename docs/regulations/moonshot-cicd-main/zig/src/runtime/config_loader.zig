const std = @import("std");
const entities = @import("../domain/entities.zig");

pub const ConfigLoadError = error{
    ConfigReadFailed,
    InvalidJson,
    InvalidYaml,
};

const Line = struct {
    raw: []const u8,
    indent: usize,
    content: []const u8,
};

const KeyValue = struct {
    key: []const u8,
    value_raw: []const u8,
};

const YamlParser = struct {
    allocator: std.mem.Allocator,
    lines: []const Line,
    index: usize = 0,

    fn parseDocument(self: *YamlParser) ConfigLoadError!std.json.Value {
        if (self.peekMeaningful()) |line| {
            return self.parseNodeAtIndent(line.indent);
        }
        const empty_obj = std.json.ObjectMap.init(self.allocator);
        return .{ .object = empty_obj };
    }

    fn parseNodeAtIndent(self: *YamlParser, indent: usize) ConfigLoadError!std.json.Value {
        const line = self.peekMeaningful() orelse return .null;
        if (line.indent < indent) return ConfigLoadError.InvalidYaml;
        if (startsWithDash(line.content)) {
            return self.parseSequence(indent);
        }
        return self.parseMapping(indent);
    }

    fn parseMapping(self: *YamlParser, indent: usize) ConfigLoadError!std.json.Value {
        var object = std.json.ObjectMap.init(self.allocator);
        while (true) {
            const line = self.peekMeaningful() orelse break;
            if (line.indent < indent) break;
            if (line.indent > indent or startsWithDash(line.content)) {
                return ConfigLoadError.InvalidYaml;
            }

            _ = self.popMeaningful() orelse return ConfigLoadError.InvalidYaml;
            const kv = splitKeyValue(line.content) catch return ConfigLoadError.InvalidYaml;
            const value = try self.parseMapValue(indent, kv.value_raw);
            object.put(kv.key, value) catch return ConfigLoadError.InvalidYaml;
        }
        return .{ .object = object };
    }

    fn parseMapEntriesInto(
        self: *YamlParser,
        object: *std.json.ObjectMap,
        entry_indent: usize,
        parent_indent: usize,
    ) ConfigLoadError!void {
        while (true) {
            const line = self.peekMeaningful() orelse break;
            if (line.indent <= parent_indent) break;
            if (line.indent < entry_indent) break;
            if (line.indent > entry_indent or startsWithDash(line.content)) {
                return ConfigLoadError.InvalidYaml;
            }

            _ = self.popMeaningful() orelse return ConfigLoadError.InvalidYaml;
            const kv = splitKeyValue(line.content) catch return ConfigLoadError.InvalidYaml;
            const value = try self.parseMapValue(entry_indent, kv.value_raw);
            object.put(kv.key, value) catch return ConfigLoadError.InvalidYaml;
        }
    }

    fn parseMapValue(self: *YamlParser, key_indent: usize, value_raw: []const u8) ConfigLoadError!std.json.Value {
        const cleaned = std.mem.trim(u8, stripInlineComment(value_raw), " \t");
        if (cleaned.len == 0) {
            const maybe_next = self.peekMeaningful();
            if (maybe_next == null or maybe_next.?.indent <= key_indent) return .null;
            return self.parseNodeAtIndent(maybe_next.?.indent);
        }
        if (isBlockScalarToken(cleaned)) {
            const strip_newline = std.mem.eql(u8, cleaned, "|-");
            const block = try self.parseBlockScalar(key_indent + 2, strip_newline);
            return .{ .string = block };
        }
        return parseScalar(self.allocator, cleaned);
    }

    fn parseSequence(self: *YamlParser, indent: usize) ConfigLoadError!std.json.Value {
        var array = std.json.Array.init(self.allocator);
        while (true) {
            const line = self.peekMeaningful() orelse break;
            if (line.indent < indent) break;
            if (line.indent != indent or !startsWithDash(line.content)) break;

            _ = self.popMeaningful() orelse return ConfigLoadError.InvalidYaml;
            const raw_item = std.mem.trimLeft(u8, line.content[2..], " \t");
            const item_token = std.mem.trim(u8, stripInlineComment(raw_item), " \t");

            if (item_token.len == 0) {
                const maybe_next = self.peekMeaningful();
                if (maybe_next == null or maybe_next.?.indent <= indent) {
                    array.append(.null) catch return ConfigLoadError.InvalidYaml;
                } else {
                    array.append(try self.parseNodeAtIndent(maybe_next.?.indent)) catch {
                        return ConfigLoadError.InvalidYaml;
                    };
                }
                continue;
            }

            if (looksLikeKeyValue(item_token)) {
                var object = std.json.ObjectMap.init(self.allocator);
                const kv = splitKeyValue(item_token) catch return ConfigLoadError.InvalidYaml;
                const first_value = try self.parseMapValue(indent + 2, kv.value_raw);
                object.put(kv.key, first_value) catch return ConfigLoadError.InvalidYaml;
                try self.parseMapEntriesInto(&object, indent + 2, indent);
                array.append(.{ .object = object }) catch return ConfigLoadError.InvalidYaml;
            } else {
                const scalar = try parseScalar(self.allocator, item_token);
                array.append(scalar) catch return ConfigLoadError.InvalidYaml;
            }
        }
        return .{ .array = array };
    }

    fn parseBlockScalar(
        self: *YamlParser,
        base_indent: usize,
        strip_final_newline: bool,
    ) ConfigLoadError![]u8 {
        var out = std.ArrayList(u8){};
        defer out.deinit(self.allocator);
        const writer = out.writer(self.allocator);

        while (self.index < self.lines.len) {
            const line = self.lines[self.index];
            const trimmed_all = std.mem.trim(u8, line.raw, " \t");
            if (trimmed_all.len != 0 and line.indent < base_indent) break;

            self.index += 1;
            if (trimmed_all.len == 0) {
                writer.writeByte('\n') catch return ConfigLoadError.InvalidYaml;
                continue;
            }

            if (line.indent >= base_indent) {
                writer.writeAll(line.raw[base_indent..]) catch return ConfigLoadError.InvalidYaml;
            }
            writer.writeByte('\n') catch return ConfigLoadError.InvalidYaml;
        }

        if (strip_final_newline and out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
            out.items.len -= 1;
        }

        return out.toOwnedSlice(self.allocator) catch return ConfigLoadError.InvalidYaml;
    }

    fn peekMeaningful(self: *YamlParser) ?Line {
        var cursor = self.index;
        while (cursor < self.lines.len) : (cursor += 1) {
            const line = self.lines[cursor];
            if (isIgnorableLine(line)) continue;
            return line;
        }
        return null;
    }

    fn popMeaningful(self: *YamlParser) ?Line {
        while (self.index < self.lines.len) : (self.index += 1) {
            const line = self.lines[self.index];
            if (isIgnorableLine(line)) continue;
            self.index += 1;
            return line;
        }
        return null;
    }
};

pub fn loadJsonFromConfigPath(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    config_path: []const u8,
) ConfigLoadError![]u8 {
    const content = try readConfigFile(allocator, project_root, config_path);
    errdefer allocator.free(content);

    if (std.mem.endsWith(u8, config_path, ".json")) {
        validateJson(content) catch return ConfigLoadError.InvalidJson;
        return content;
    }
    if (std.mem.endsWith(u8, config_path, ".yaml") or std.mem.endsWith(u8, config_path, ".yml")) {
        const converted = try yamlToJson(allocator, content);
        allocator.free(content);
        return converted;
    }

    if (validateJson(content)) {
        return content;
    } else |_| {
        const converted = try yamlToJson(allocator, content);
        allocator.free(content);
        return converted;
    }
}

pub fn loadFromConfigPath(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    config_path: []const u8,
) ConfigLoadError!entities.AppConfigEntity {
    const json_text = try loadJsonFromConfigPath(
        allocator,
        project_root,
        config_path,
    );
    defer allocator.free(json_text);
    return entities.AppConfigEntity.fromJsonText(allocator, json_text) catch {
        return ConfigLoadError.InvalidJson;
    };
}

fn readConfigFile(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    config_path: []const u8,
) ConfigLoadError![]u8 {
    const resolved_path = blk: {
        if (std.fs.path.isAbsolute(config_path)) {
            break :blk allocator.dupe(u8, config_path) catch return ConfigLoadError.ConfigReadFailed;
        }

        const candidate = std.fs.path.join(allocator, &.{ project_root, config_path }) catch {
            break :blk allocator.dupe(u8, config_path) catch return ConfigLoadError.ConfigReadFailed;
        };
        if (pathExists(candidate)) {
            break :blk candidate;
        }

        allocator.free(candidate);
        break :blk allocator.dupe(u8, config_path) catch return ConfigLoadError.ConfigReadFailed;
    };
    defer allocator.free(resolved_path);

    const file = if (std.fs.path.isAbsolute(resolved_path))
        std.fs.openFileAbsolute(resolved_path, .{})
    else
        std.fs.cwd().openFile(resolved_path, .{});
    const handle = file catch return ConfigLoadError.ConfigReadFailed;
    defer handle.close();

    return handle.readToEndAlloc(allocator, 32 * 1024 * 1024) catch ConfigLoadError.ConfigReadFailed;
}

fn validateJson(content: []const u8) ConfigLoadError!void {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, content, .{}) catch {
        return ConfigLoadError.InvalidJson;
    };
    defer parsed.deinit();
}

fn yamlToJson(allocator: std.mem.Allocator, content: []const u8) ConfigLoadError![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    const lines = try buildLines(temp_allocator, content);
    var parser = YamlParser{
        .allocator = temp_allocator,
        .lines = lines,
        .index = 0,
    };
    const root_value = parser.parseDocument() catch return ConfigLoadError.InvalidYaml;
    return std.json.Stringify.valueAlloc(allocator, root_value, .{}) catch ConfigLoadError.InvalidYaml;
}

fn buildLines(allocator: std.mem.Allocator, content: []const u8) ConfigLoadError![]Line {
    var lines: std.ArrayList(Line) = .{};
    defer lines.deinit(allocator);

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line_raw| {
        const raw = std.mem.trimRight(u8, line_raw, "\r");
        const indent = countIndent(raw);
        lines.append(allocator, .{
            .raw = raw,
            .indent = indent,
            .content = raw[indent..],
        }) catch return ConfigLoadError.InvalidYaml;
    }

    return lines.toOwnedSlice(allocator) catch return ConfigLoadError.InvalidYaml;
}

fn countIndent(line: []const u8) usize {
    var index: usize = 0;
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}
    return index;
}

fn isIgnorableLine(line: Line) bool {
    const trimmed = std.mem.trim(u8, line.content, " \t");
    if (trimmed.len == 0) return true;
    if (trimmed[0] == '#') return true;
    return std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "...");
}

fn startsWithDash(content: []const u8) bool {
    return std.mem.startsWith(u8, content, "- ");
}

fn looksLikeKeyValue(value: []const u8) bool {
    const colon_index = findKeyColon(value) orelse return false;
    return colon_index > 0;
}

fn splitKeyValue(content: []const u8) ConfigLoadError!KeyValue {
    const colon_index = findKeyColon(content) orelse return ConfigLoadError.InvalidYaml;
    if (colon_index == 0) return ConfigLoadError.InvalidYaml;

    const key = std.mem.trim(u8, content[0..colon_index], " \t");
    if (key.len == 0) return ConfigLoadError.InvalidYaml;
    const value_raw = std.mem.trimLeft(u8, content[colon_index + 1 ..], " \t");
    return .{ .key = key, .value_raw = value_raw };
}

fn findKeyColon(content: []const u8) ?usize {
    var quote: u8 = 0;
    var escaped = false;

    for (content, 0..) |char, idx| {
        if (quote != 0) {
            if (quote == '"' and char == '\\' and !escaped) {
                escaped = true;
                continue;
            }
            if (char == quote and !escaped) quote = 0;
            escaped = false;
            continue;
        }

        if (char == '"' or char == '\'') {
            quote = char;
            escaped = false;
            continue;
        }
        if (char == ':') return idx;
    }
    return null;
}

fn stripInlineComment(value: []const u8) []const u8 {
    if (value.len == 0) return value;
    if ((value[0] == '"' and value[value.len - 1] == '"') or
        (value[0] == '\'' and value[value.len - 1] == '\''))
    {
        return value;
    }

    var quote: u8 = 0;
    var escaped = false;
    for (value, 0..) |char, idx| {
        if (quote != 0) {
            if (quote == '"' and char == '\\' and !escaped) {
                escaped = true;
                continue;
            }
            if (char == quote and !escaped) quote = 0;
            escaped = false;
            continue;
        }

        if (char == '"' or char == '\'') {
            quote = char;
            escaped = false;
            continue;
        }
        if (char == '#' and (idx == 0 or value[idx - 1] == ' ' or value[idx - 1] == '\t')) {
            return value[0..idx];
        }
    }
    return value;
}

fn isBlockScalarToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "|") or std.mem.eql(u8, token, "|-");
}

fn parseScalar(allocator: std.mem.Allocator, token: []const u8) ConfigLoadError!std.json.Value {
    const value = std.mem.trim(u8, token, " \t");
    if (value.len == 0) return .null;

    if (std.mem.eql(u8, value, "~") or std.ascii.eqlIgnoreCase(value, "null")) return .null;
    if (std.ascii.eqlIgnoreCase(value, "true")) return .{ .bool = true };
    if (std.ascii.eqlIgnoreCase(value, "false")) return .{ .bool = false };

    if (std.fmt.parseInt(i64, value, 10)) |integer| {
        return .{ .integer = integer };
    } else |_| {}

    if (std.fmt.parseFloat(f64, value)) |float_value| {
        return .{ .float = float_value };
    } else |_| {}

    if (value.len >= 2 and
        ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        const inner = value[1 .. value.len - 1];
        return .{ .string = allocator.dupe(u8, inner) catch return ConfigLoadError.InvalidYaml };
    }

    return .{ .string = allocator.dupe(u8, value) catch return ConfigLoadError.InvalidYaml };
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
    } else {
        std.fs.cwd().access(path, .{}) catch return false;
    }
    return true;
}
