//! storage/table/rel_table_data parity module.

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
    return "storage/table/rel_table_data";
}

test "rel_table_data module path" {
    try std.testing.expectEqualStrings("storage/table/rel_table_data", modulePath());
}

test "rel_table_data resolved tag fallback" {
    var node = ParityNode.init("");
    try std.testing.expect(node.tagMatches("storage/table/rel_table_data"));
}
