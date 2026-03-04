//! StatementType
const std = @import("std");

pub const StatementType = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) StatementType { return .{ .allocator = allocator }; }
    pub fn deinit(self: *StatementType) void { _ = self; }
};

test "StatementType" {
    const allocator = std.testing.allocator;
    var instance = StatementType.init(allocator);
    defer instance.deinit();
}
