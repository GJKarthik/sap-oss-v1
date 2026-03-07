//! common/arrow/arrow_null_mask_tree parity module.

const std = @import("std");

pub const ParityNode = struct {
    tag: []const u8,

    pub fn init(tag: []const u8) ParityNode {
        return .{ .tag = tag };
    }

    pub fn resolvedTag(self: *const ParityNode) []const u8 {
        return if (self.tag.len == 0) modulePath() else self.tag;
    }

    pub fn tagMatches(self: *const ParityNode, expected: []const u8) bool {
        return std.mem.eql(u8, self.resolvedTag(), expected);
    }
};

pub fn modulePath() []const u8 {
    return "common/arrow/arrow_null_mask_tree";
}

test "arrow_null_mask_tree module path" {
    try std.testing.expectEqualStrings("common/arrow/arrow_null_mask_tree", modulePath());
}

test "arrow_null_mask_tree resolved tag fallback" {
    var node = ParityNode.init("");
    try std.testing.expect(node.tagMatches("common/arrow/arrow_null_mask_tree"));
}
