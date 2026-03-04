//! LogicalScanNodeProperty
const std = @import("std");

pub const LogicalScanNodeProperty = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalScanNodeProperty { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalScanNodeProperty) void { _ = self; }
};

test "LogicalScanNodeProperty" {
    const allocator = std.testing.allocator;
    var instance = LogicalScanNodeProperty.init(allocator);
    defer instance.deinit();
}
