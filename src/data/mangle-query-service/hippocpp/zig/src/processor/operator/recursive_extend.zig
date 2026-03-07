//! Recursive extension planning helpers.

const std = @import("std");

pub fn nextDepth(current_depth: u32, max_depth: u32) ?u32 {
    if (current_depth >= max_depth) return null;
    return current_depth + 1;
}

test "next depth" {
    try std.testing.expectEqual(@as(u32, 2), nextDepth(1, 3).?);
    try std.testing.expect(nextDepth(3, 3) == null);
}
