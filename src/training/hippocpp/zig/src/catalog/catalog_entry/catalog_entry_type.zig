//! catalog/catalog_entry/catalog_entry_type parity module.

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
    return "catalog/catalog_entry/catalog_entry_type";
}

test "catalog_entry_type module path" {
    try std.testing.expectEqualStrings("catalog/catalog_entry/catalog_entry_type", modulePath());
}

test "catalog_entry_type resolved tag fallback" {
    var node = ParityNode.init("");
    try std.testing.expect(node.tagMatches("catalog/catalog_entry/catalog_entry_type"));
}
