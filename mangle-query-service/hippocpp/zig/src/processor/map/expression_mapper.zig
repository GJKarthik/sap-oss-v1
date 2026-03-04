//! Expression mapping helpers for processor map layer.

const std = @import("std");
const plan_mapper = @import("plan_mapper.zig");

/// Normalize expression strings to a stable single-line representation
/// so map rules can compare equivalent expressions consistently.
pub fn normalizeExpression(allocator: std.mem.Allocator, expr: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    var prev_space = false;
    for (expr) |ch| {
        const is_space = std.ascii.isWhitespace(ch);
        if (is_space) {
            if (!prev_space and out.items.len > 0) {
                try out.append(' ');
                prev_space = true;
            }
            continue;
        }
        try out.append(ch);
        prev_space = false;
    }

    // Trim a trailing separator produced by whitespace folding.
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }

    return out.toOwnedSlice();
}

pub fn mapSpec() plan_mapper.MapOpSpec {
    return plan_mapper.make(
        "expression_mapper",
        "processor/operator/physical_operator.zig",
        true,
        false,
    );
}

test "normalize expression" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeExpression(allocator, "  a +   b\t\n +  c  ");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("a + b + c", normalized);
}
