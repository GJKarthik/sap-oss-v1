//! JSON utility functions for safe string handling

const std = @import("std");

/// Escape a string for safe inclusion in JSON
pub fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var list = std.ArrayListUnmanaged(u8){};
    errdefer list.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0x08 => try list.appendSlice(allocator, "\\b"), // backspace
            0x0C => try list.appendSlice(allocator, "\\f"), // form feed
            else => |ch| {
                if (ch < 0x20) {
                    var buf: [6]u8 = undefined;
                    const len = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch unreachable;
                    try list.appendSlice(allocator, len);
                } else {
                    try list.append(allocator, ch);
                }
            },
        }
    }

    return list.toOwnedSlice(allocator);
}

test "jsonEscape plain text" {
    const result = try jsonEscape(std.testing.allocator, "hello world");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "jsonEscape quotes and backslashes" {
    const result = try jsonEscape(std.testing.allocator, "say \"hello\\world\"");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("say \\\"hello\\\\world\\\"", result);
}

test "jsonEscape control characters" {
    const result = try jsonEscape(std.testing.allocator, "line1\nline2\ttab");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("line1\\nline2\\ttab", result);
}