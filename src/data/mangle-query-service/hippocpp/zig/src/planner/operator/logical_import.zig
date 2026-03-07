//! LogicalImport
const std = @import("std");

pub const LogicalImport = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalImport { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalImport) void { _ = self; }
};

test "LogicalImport" {
    const allocator = std.testing.allocator;
    var instance = LogicalImport.init(allocator);
    defer instance.deinit();
}
