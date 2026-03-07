//! parser/expression/parsed_expression_visitor parity module.

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
    return "parser/expression/parsed_expression_visitor";
}

test "parsed_expression_visitor module path" {
    try std.testing.expectEqualStrings("parser/expression/parsed_expression_visitor", modulePath());
}

test "parsed_expression_visitor resolved tag fallback" {
    var node = ParityNode.init("");
    try std.testing.expect(node.tagMatches("parser/expression/parsed_expression_visitor"));
}
