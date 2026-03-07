//! MatchClause
const std = @import("std");

pub const MatchClause = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) MatchClause { return .{ .allocator = allocator }; }
    pub fn deinit(self: *MatchClause) void { _ = self; }
};

test "MatchClause" {
    const allocator = std.testing.allocator;
    var instance = MatchClause.init(allocator);
    defer instance.deinit();
}
