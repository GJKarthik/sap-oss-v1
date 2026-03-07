//! graph/on_disk_graph parity module.

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
    return "graph/on_disk_graph";
}

test "on_disk_graph module path" {
    try std.testing.expectEqualStrings("graph/on_disk_graph", modulePath());
}

test "on_disk_graph resolved tag fallback" {
    var node = ParityNode.init("");
    try std.testing.expect(node.tagMatches("graph/on_disk_graph"));
}
