//! optimizer/projection_push_down_optimizer parity module.

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
    return "optimizer/projection_push_down_optimizer";
}

test "projection_push_down_optimizer module path" {
    try std.testing.expectEqualStrings("optimizer/projection_push_down_optimizer", modulePath());
}

test "projection_push_down_optimizer resolved tag fallback" {
    var node = ParityNode.init("");
    try std.testing.expect(node.tagMatches("optimizer/projection_push_down_optimizer"));
}
