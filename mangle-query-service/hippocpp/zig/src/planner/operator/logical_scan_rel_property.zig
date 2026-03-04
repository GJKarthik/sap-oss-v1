//! LogicalScanRelProperty
const std = @import("std");

pub const LogicalScanRelProperty = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalScanRelProperty { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalScanRelProperty) void { _ = self; }
};

test "LogicalScanRelProperty" {
    const allocator = std.testing.allocator;
    var instance = LogicalScanRelProperty.init(allocator);
    defer instance.deinit();
}
