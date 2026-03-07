//! UnwindClause
const std = @import("std");

pub const UnwindClause = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) UnwindClause { return .{ .allocator = allocator }; }
    pub fn deinit(self: *UnwindClause) void { _ = self; }
};

test "UnwindClause" {
    const allocator = std.testing.allocator;
    var instance = UnwindClause.init(allocator);
    defer instance.deinit();
}
