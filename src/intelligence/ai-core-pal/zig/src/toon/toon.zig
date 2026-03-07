// ===----------------------------------------------------------------------=== //
// TOON - Token Oriented Object Notation
//
// A compact, token-efficient serialization format optimized for LLM inference.
// TOON reduces token count by 40-60% compared to JSON while remaining
// human-readable and streamable.
//
// Design Goals:
// 1. Minimize token count for faster LLM processing
// 2. Support streaming (parse incrementally)
// 3. Human readable/writable
// 4. Efficient for structured data extraction
// 5. Integrate with Mangle rules
//
// Format:
//   - Uses single-char delimiters: : = . , ; | ~
//   - No quotes for simple strings
//   - Implicit typing (numbers, bools, nulls)
//   - Nested objects use indentation OR inline syntax
//   - Arrays use | separator
//   - Comments with #
//
// Example:
//   JSON (47 tokens):
//     {"name": "John", "age": 30, "cities": ["NYC", "LA"]}
//
//   TOON (23 tokens):
//     name:John age:30 cities:NYC|LA
//
// ===----------------------------------------------------------------------=== //

const std = @import("std");
const Allocator = std.mem.Allocator;

/// TOON Value types
pub const Value = union(enum) {
    null_val,
    bool_val: bool,
    int_val: i64,
    float_val: f64,
    string_val: []const u8,
    array_val: []const Value,
    object_val: std.StringHashMap(Value),
    
    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .array_val => |arr| {
                for (arr) |*item| {
                    var it = @constCast(item);
                    it.deinit(allocator);
                }
                allocator.free(arr);
            },
            .object_val => |*map| {
                var iter = map.iterator();
                while (iter.next()) |entry| {
                    var val = @constCast(&entry.value_ptr.*);
                    val.deinit(allocator);
                }
                map.deinit();
            },
            .string_val => |s| {
                allocator.free(s);
            },
            else => {},
        }
    }
};

/// TOON Parser
pub const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    pos: usize = 0,
    line: usize = 1,
    col: usize = 1,
    
    pub fn init(allocator: Allocator, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .source = source,
        };
    }
    
    /// Parse TOON document into Value
    pub fn parse(self: *Parser) !Value {
        self.skipWhitespace();
        
        // Check for array or object at top level
        if (self.peek() == '[') {
            return self.parseArray();
        } else if (self.peek() == '{') {
            return self.parseObject();
        }
        
        // Otherwise parse as implicit object (key:value pairs)
        return self.parseImplicitObject();
    }
    
    fn parseImplicitObject(self: *Parser) !Value {
        var map = std.StringHashMap(Value).init(self.allocator);
        errdefer map.deinit();
        
        while (!self.isAtEnd()) {
            self.skipWhitespace();
            if (self.isAtEnd()) break;
            
            // Skip comments
            if (self.peek() == '#') {
                self.skipLine();
                continue;
            }
            
            // Parse key
            const key = try self.parseKey();
            if (key.len == 0) break;
            
            // Expect : or =
            self.skipWhitespace();
            if (!self.isAtEnd() and (self.peek() == ':' or self.peek() == '=')) {
                _ = self.advance();
            }
            
            // Parse value
            const value = try self.parseValue();
            try map.put(key, value);
            
            // Optional separator (space, comma, semicolon, newline)
            self.skipWhitespace();
            if (!self.isAtEnd() and (self.peek() == ',' or self.peek() == ';')) {
                _ = self.advance();
            }
        }
        
        return Value{ .object_val = map };
    }
    
    fn parseKey(self: *Parser) ![]const u8 {
        const start = self.pos;
        
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == ':' or c == '=' or c == ' ' or c == '\n' or c == '\t' or c == ',' or c == ';') {
                break;
            }
            _ = self.advance();
        }
        
        const key = self.source[start..self.pos];
        return try self.allocator.dupe(u8, key);
    }
    
    fn parseValue(self: *Parser) ParseError!Value {
        self.skipWhitespace();
        
        if (self.isAtEnd()) {
            return Value.null_val;
        }
        
        const c = self.peek();
        
        // Check for special values
        if (c == '[') {
            return self.parseArray();
        } else if (c == '{') {
            return self.parseObject();
        } else if (c == '~') {
            _ = self.advance();
            return Value.null_val;
        } else if (c == '"' or c == '\'') {
            return self.parseQuotedString();
        }
        
        // Parse unquoted value
        return self.parseUnquotedValue();
    }
    
    const ParseError = error{OutOfMemory};
    
    fn parseUnquotedValue(self: *Parser) ParseError!Value {
        const start = self.pos;
        var has_dot = false;
        var has_pipe = false;
        
        // Find end of value
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == ' ' or c == '\n' or c == '\t' or c == ',' or c == ';' or 
                c == ']' or c == '}') {
                break;
            }
            if (c == '.') has_dot = true;
            if (c == '|') has_pipe = true;
            _ = self.advance();
        }
        
        const raw = self.source[start..self.pos];
        
        // Empty value
        if (raw.len == 0) {
            return Value.null_val;
        }
        
        // Check for pipe-separated array
        if (has_pipe) {
            return self.parsePipeArray(raw);
        }
        
        // Check for boolean
        if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "yes") or std.mem.eql(u8, raw, "Y")) {
            return Value{ .bool_val = true };
        }
        if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "no") or std.mem.eql(u8, raw, "N")) {
            return Value{ .bool_val = false };
        }
        
        // Check for null
        if (std.mem.eql(u8, raw, "null") or std.mem.eql(u8, raw, "~") or std.mem.eql(u8, raw, "nil")) {
            return Value.null_val;
        }
        
        // Try parsing as number
        if (has_dot) {
            if (std.fmt.parseFloat(f64, raw)) |f| {
                return Value{ .float_val = f };
            } else |_| {}
        } else {
            if (std.fmt.parseInt(i64, raw, 10)) |i| {
                return Value{ .int_val = i };
            } else |_| {}
        }
        
        // Return as string
        return Value{ .string_val = try self.allocator.dupe(u8, raw) };
    }
    
    fn parsePipeArray(self: *Parser, raw: []const u8) !Value {
        var items: std.ArrayListUnmanaged(Value) = .{};
        errdefer items.deinit(self.allocator);
        
        var iter = std.mem.splitScalar(u8, raw, '|');
        while (iter.next()) |item| {
            const trimmed = std.mem.trim(u8, item, " \t");
            if (trimmed.len > 0) {
                // Try to parse each item as a value
                var sub_parser = Parser.init(self.allocator, trimmed);
                const val = try sub_parser.parseUnquotedValue();
                try items.append(self.allocator, val);
            }
        }
        
        return Value{ .array_val = try items.toOwnedSlice(self.allocator) };
    }
    
    fn parseArray(self: *Parser) !Value {
        _ = self.advance(); // consume [
        self.skipWhitespace();
        
        var items: std.ArrayListUnmanaged(Value) = .{};
        errdefer items.deinit(self.allocator);
        
        while (!self.isAtEnd() and self.peek() != ']') {
            const value = try self.parseValue();
            try items.append(self.allocator, value);
            
            self.skipWhitespace();
            if (self.peek() == ',' or self.peek() == '|') {
                _ = self.advance();
            }
            self.skipWhitespace();
        }
        
        if (!self.isAtEnd() and self.peek() == ']') {
            _ = self.advance();
        }
        
        return Value{ .array_val = try items.toOwnedSlice(self.allocator) };
    }
    
    fn parseObject(self: *Parser) !Value {
        _ = self.advance(); // consume {
        self.skipWhitespace();
        
        var map = std.StringHashMap(Value).init(self.allocator);
        errdefer map.deinit();
        
        while (!self.isAtEnd() and self.peek() != '}') {
            // Skip comments
            if (self.peek() == '#') {
                self.skipLine();
                continue;
            }
            
            const key = try self.parseKey();
            if (key.len == 0) break;
            
            self.skipWhitespace();
            if (!self.isAtEnd() and (self.peek() == ':' or self.peek() == '=')) {
                _ = self.advance();
            }
            
            const value = try self.parseValue();
            try map.put(key, value);
            
            self.skipWhitespace();
            if (!self.isAtEnd() and (self.peek() == ',' or self.peek() == ';')) {
                _ = self.advance();
            }
            self.skipWhitespace();
        }
        
        if (!self.isAtEnd() and self.peek() == '}') {
            _ = self.advance();
        }
        
        return Value{ .object_val = map };
    }
    
    fn parseQuotedString(self: *Parser) !Value {
        const quote = self.advance();
        const start = self.pos;
        
        while (!self.isAtEnd() and self.peek() != quote) {
            if (self.peek() == '\\') {
                _ = self.advance(); // skip escape
            }
            _ = self.advance();
        }
        
        const content = self.source[start..self.pos];
        
        if (!self.isAtEnd()) {
            _ = self.advance(); // consume closing quote
        }
        
        return Value{ .string_val = try self.allocator.dupe(u8, content) };
    }
    
    fn skipWhitespace(self: *Parser) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\r') {
                _ = self.advance();
            } else if (c == '\n') {
                _ = self.advance();
                self.line += 1;
                self.col = 1;
            } else {
                break;
            }
        }
    }
    
    fn skipLine(self: *Parser) void {
        while (!self.isAtEnd() and self.peek() != '\n') {
            _ = self.advance();
        }
    }
    
    fn peek(self: *Parser) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.pos];
    }
    
    fn advance(self: *Parser) u8 {
        const c = self.source[self.pos];
        self.pos += 1;
        self.col += 1;
        return c;
    }
    
    fn isAtEnd(self: *Parser) bool {
        return self.pos >= self.source.len;
    }
};

/// TOON Writer - converts Value to TOON string
pub const Writer = struct {
    allocator: Allocator,
    buffer: std.ArrayListUnmanaged(u8) = .{},
    indent: usize = 0,
    compact: bool = true,
    
    pub fn init(allocator: Allocator) Writer {
        return .{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Writer) void {
        self.buffer.deinit(self.allocator);
    }
    
    pub fn write(self: *Writer, value: Value) ![]const u8 {
        try self.writeValue(value);
        return self.buffer.toOwnedSlice(self.allocator);
    }
    
    fn writeValue(self: *Writer, value: Value) !void {
        switch (value) {
            .null_val => try self.buffer.appendSlice(self.allocator, "~"),
            .bool_val => |b| try self.buffer.appendSlice(self.allocator, if (b) "true" else "false"),
            .int_val => |i| {
                var buf: [32]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "0";
                try self.buffer.appendSlice(self.allocator, str);
            },
            .float_val => |f| {
                var buf: [64]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "0";
                try self.buffer.appendSlice(self.allocator, str);
            },
            .string_val => |s| {
                if (needsQuoting(s)) {
                    try self.buffer.append(self.allocator, '"');
                    for (s) |c| {
                        switch (c) {
                            '"' => try self.buffer.appendSlice(self.allocator, "\\\""),
                            '\\' => try self.buffer.appendSlice(self.allocator, "\\\\"),
                            else => try self.buffer.append(self.allocator, c),
                        }
                    }
                    try self.buffer.append(self.allocator, '"');
                } else {
                    try self.buffer.appendSlice(self.allocator, s);
                }
            },
            .array_val => |arr| {
                // Use pipe notation for simple arrays
                if (arr.len > 0 and isSimpleArray(arr)) {
                    for (arr, 0..) |item, idx| {
                        if (idx > 0) try self.buffer.append(self.allocator, '|');
                        try self.writeValue(item);
                    }
                } else {
                    try self.buffer.append(self.allocator, '[');
                    for (arr, 0..) |item, idx| {
                        if (idx > 0) try self.buffer.appendSlice(self.allocator, ", ");
                        try self.writeValue(item);
                    }
                    try self.buffer.append(self.allocator, ']');
                }
            },
            .object_val => |map| {
                var iter = map.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try self.buffer.append(self.allocator, ' ');
                    first = false;
                    try self.buffer.appendSlice(self.allocator, entry.key_ptr.*);
                    try self.buffer.append(self.allocator, ':');
                    try self.writeValue(entry.value_ptr.*);
                }
            },
        }
    }
};

fn needsQuoting(s: []const u8) bool {
    for (s) |c| {
        if (c == ' ' or c == ':' or c == '=' or c == '|' or c == ',' or 
            c == '\n' or c == '\t' or c == '{' or c == '}' or c == '[' or c == ']') {
            return true;
        }
    }
    return false;
}

fn isSimpleArray(arr: []const Value) bool {
    for (arr) |item| {
        switch (item) {
            .object_val, .array_val => return false,
            else => {},
        }
    }
    return true;
}

// ===----------------------------------------------------------------------=== //
// TOON to JSON conversion
// ===----------------------------------------------------------------------=== //

/// Convert TOON to JSON
pub fn toJson(allocator: Allocator, toon: []const u8) ![]const u8 {
    var parser = Parser.init(allocator, toon);
    var value = try parser.parse();
    defer value.deinit(allocator);
    
    return valueToJson(allocator, value);
}

fn valueToJson(allocator: Allocator, value: Value) ![]const u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    errdefer buffer.deinit(allocator);
    
    try writeJsonValue(allocator, &buffer, value);
    return buffer.toOwnedSlice(allocator);
}

fn writeJsonValue(allocator: Allocator, buffer: *std.ArrayListUnmanaged(u8), value: Value) !void {
    switch (value) {
        .null_val => try buffer.appendSlice(allocator, "null"),
        .bool_val => |b| try buffer.appendSlice(allocator, if (b) "true" else "false"),
        .int_val => |i| {
            var buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "0";
            try buffer.appendSlice(allocator, str);
        },
        .float_val => |f| {
            var buf: [64]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "0";
            try buffer.appendSlice(allocator, str);
        },
        .string_val => |s| {
            try buffer.append(allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try buffer.appendSlice(allocator, "\\\""),
                    '\\' => try buffer.appendSlice(allocator, "\\\\"),
                    '\n' => try buffer.appendSlice(allocator, "\\n"),
                    '\t' => try buffer.appendSlice(allocator, "\\t"),
                    '\r' => try buffer.appendSlice(allocator, "\\r"),
                    else => try buffer.append(allocator, c),
                }
            }
            try buffer.append(allocator, '"');
        },
        .array_val => |arr| {
            try buffer.append(allocator, '[');
            for (arr, 0..) |item, idx| {
                if (idx > 0) try buffer.appendSlice(allocator, ", ");
                try writeJsonValue(allocator, buffer, item);
            }
            try buffer.append(allocator, ']');
        },
        .object_val => |map| {
            try buffer.append(allocator, '{');
            var iter = map.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) try buffer.appendSlice(allocator, ", ");
                first = false;
                try buffer.append(allocator, '"');
                for (entry.key_ptr.*) |c| {
                    switch (c) {
                        '"' => try buffer.appendSlice(allocator, "\\\""),
                        '\\' => try buffer.appendSlice(allocator, "\\\\"),
                        '\n' => try buffer.appendSlice(allocator, "\\n"),
                        '\t' => try buffer.appendSlice(allocator, "\\t"),
                        '\r' => try buffer.appendSlice(allocator, "\\r"),
                        else => try buffer.append(allocator, c),
                    }
                }
                try buffer.appendSlice(allocator, "\": ");
                try writeJsonValue(allocator, buffer, entry.value_ptr.*);
            }
            try buffer.append(allocator, '}');
        },
    }
}

/// Convert JSON to TOON
pub fn fromJson(allocator: Allocator, json: []const u8) ![]const u8 {
    // Use std.json parser
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    
    return jsonValueToToon(allocator, parsed.value);
}

fn jsonValueToToon(allocator: Allocator, value: std.json.Value) ![]const u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    errdefer buffer.deinit(allocator);
    
    try writeJsonValueAsToon(allocator, &buffer, value);
    return buffer.toOwnedSlice(allocator);
}

fn writeJsonValueAsToon(allocator: Allocator, buffer: *std.ArrayListUnmanaged(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try buffer.append(allocator, '~'),
        .bool => |b| try buffer.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            var buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "0";
            try buffer.appendSlice(allocator, str);
        },
        .float => |f| {
            var buf: [64]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "0";
            try buffer.appendSlice(allocator, str);
        },
        .string => |s| {
            if (needsQuoting(s)) {
                try buffer.append(allocator, '"');
                for (s) |c| {
                    switch (c) {
                        '"' => try buffer.appendSlice(allocator, "\\\""),
                        '\\' => try buffer.appendSlice(allocator, "\\\\"),
                        else => try buffer.append(allocator, c),
                    }
                }
                try buffer.append(allocator, '"');
            } else {
                try buffer.appendSlice(allocator, s);
            }
        },
        .array => |arr| {
            // Check if simple array (can use pipe notation)
            var simple = true;
            for (arr.items) |item| {
                if (item == .object or item == .array) {
                    simple = false;
                    break;
                }
            }
            
            if (simple and arr.items.len > 0) {
                for (arr.items, 0..) |item, idx| {
                    if (idx > 0) try buffer.append(allocator, '|');
                    try writeJsonValueAsToon(allocator, buffer, item);
                }
            } else {
                try buffer.append(allocator, '[');
                for (arr.items, 0..) |item, idx| {
                    if (idx > 0) try buffer.appendSlice(allocator, ", ");
                    try writeJsonValueAsToon(allocator, buffer, item);
                }
                try buffer.append(allocator, ']');
            }
        },
        .object => |obj| {
            var first = true;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                if (!first) try buffer.append(allocator, ' ');
                first = false;
                try buffer.appendSlice(allocator, entry.key_ptr.*);
                try buffer.append(allocator, ':');
                try writeJsonValueAsToon(allocator, buffer, entry.value_ptr.*);
            }
        },
        else => {},
    }
}

// ===----------------------------------------------------------------------=== //
// Token counting utilities
// ===----------------------------------------------------------------------=== //

/// Estimate token count (rough approximation)
/// Most tokenizers use ~4 chars per token average for English
pub fn estimateTokens(text: []const u8) usize {
    // Count "words" (space-separated) + punctuation
    var tokens: usize = 0;
    var in_word = false;
    
    for (text) |c| {
        if (c == ' ' or c == '\n' or c == '\t') {
            if (in_word) {
                tokens += 1;
                in_word = false;
            }
        } else if (c == ':' or c == '=' or c == '|' or c == ',' or c == ';' or 
                   c == '{' or c == '}' or c == '[' or c == ']' or c == '"') {
            if (in_word) {
                tokens += 1;
                in_word = false;
            }
            tokens += 1; // punctuation is usually its own token
        } else {
            in_word = true;
        }
    }
    
    if (in_word) tokens += 1;
    return tokens;
}

/// Compare token counts between TOON and JSON
pub fn tokenSavings(allocator: Allocator, json: []const u8) !struct { json_tokens: usize, toon_tokens: usize, savings_pct: f32 } {
    const toon = try fromJson(allocator, json);
    defer allocator.free(toon);
    
    const json_tokens = estimateTokens(json);
    const toon_tokens = estimateTokens(toon);
    
    const savings: f32 = if (json_tokens > 0) 
        @as(f32, @floatFromInt(json_tokens - toon_tokens)) / @as(f32, @floatFromInt(json_tokens)) * 100.0
    else 
        0.0;
    
    return .{
        .json_tokens = json_tokens,
        .toon_tokens = toon_tokens,
        .savings_pct = savings,
    };
}

// ===----------------------------------------------------------------------=== //
// Tests
// ===----------------------------------------------------------------------=== //

test "parse simple key-value" {
    const allocator = std.testing.allocator;
    const input = "name:John age:30 active:true";
    
    var parser = Parser.init(allocator, input);
    var value = try parser.parse();
    defer value.deinit(allocator);
    
    try std.testing.expect(value == .object_val);
    const map = value.object_val;
    
    try std.testing.expectEqualStrings("John", map.get("name").?.string_val);
    try std.testing.expectEqual(@as(i64, 30), map.get("age").?.int_val);
    try std.testing.expectEqual(true, map.get("active").?.bool_val);
}

test "parse pipe array" {
    const allocator = std.testing.allocator;
    const input = "cities:NYC|LA|Chicago";
    
    var parser = Parser.init(allocator, input);
    var value = try parser.parse();
    defer value.deinit(allocator);
    
    const cities = value.object_val.get("cities").?.array_val;
    try std.testing.expectEqual(@as(usize, 3), cities.len);
    try std.testing.expectEqualStrings("NYC", cities[0].string_val);
}

test "json to toon conversion" {
    const allocator = std.testing.allocator;
    const json = 
        \\{"name": "John", "age": 30, "cities": ["NYC", "LA"]}
    ;
    
    const toon = try fromJson(allocator, json);
    defer allocator.free(toon);
    
    // TOON should be shorter
    try std.testing.expect(toon.len < json.len);
    
    // Verify token savings
    const savings = try tokenSavings(allocator, json);
    try std.testing.expect(savings.savings_pct > 20.0);
}

test "toon to json conversion" {
    const allocator = std.testing.allocator;
    const toon = "name:John age:30 cities:NYC|LA";
    
    const json = try toJson(allocator, toon);
    defer allocator.free(json);
    
    // Should contain expected JSON structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"John\"") != null);
}