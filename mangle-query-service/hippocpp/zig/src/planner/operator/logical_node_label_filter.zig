//! LogicalNodeLabelFilter
const std = @import("std");

pub const LogicalNodeLabelFilter = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalNodeLabelFilter { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalNodeLabelFilter) void { _ = self; }
};

test "LogicalNodeLabelFilter" {
    const allocator = std.testing.allocator;
    var instance = LogicalNodeLabelFilter.init(allocator);
    defer instance.deinit();
}
