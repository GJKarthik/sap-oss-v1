//! optimizer/remove_factorization_rewriter parity module.

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
    return "optimizer/remove_factorization_rewriter";
}

test "remove_factorization_rewriter module path" {
    try std.testing.expectEqualStrings("optimizer/remove_factorization_rewriter", modulePath());
}

test "remove_factorization_rewriter resolved tag fallback" {
    var node = ParityNode.init("");
    try std.testing.expect(node.tagMatches("optimizer/remove_factorization_rewriter"));
}
