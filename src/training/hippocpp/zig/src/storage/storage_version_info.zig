//! storage/storage_version_info parity module.

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
    return "storage/storage_version_info";
}

test "storage_version_info module path" {
    try std.testing.expectEqualStrings("storage/storage_version_info", modulePath());
}

test "storage_version_info resolved tag fallback" {
    var node = ParityNode.init("");
    try std.testing.expect(node.tagMatches("storage/storage_version_info"));
}
