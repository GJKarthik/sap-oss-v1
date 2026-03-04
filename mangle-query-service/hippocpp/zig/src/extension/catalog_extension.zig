//! extension/catalog_extension parity module.

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
    return "extension/catalog_extension";
}

test "catalog_extension module path" {
    try std.testing.expectEqualStrings("extension/catalog_extension", modulePath());
}

test "catalog_extension resolved tag fallback" {
    var node = ParityNode.init("");
    try std.testing.expect(node.tagMatches("extension/catalog_extension"));
}
