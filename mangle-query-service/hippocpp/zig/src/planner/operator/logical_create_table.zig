//! LogicalCreateTable
const std = @import("std");

pub const LogicalCreateTable = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalCreateTable { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalCreateTable) void { _ = self; }
};

test "LogicalCreateTable" {
    const allocator = std.testing.allocator;
    var instance = LogicalCreateTable.init(allocator);
    defer instance.deinit();
}
