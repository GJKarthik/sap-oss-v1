//! LogicalExport
const std = @import("std");

pub const LogicalExport = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalExport { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalExport) void { _ = self; }
};

test "LogicalExport" {
    const allocator = std.testing.allocator;
    var instance = LogicalExport.init(allocator);
    defer instance.deinit();
}
