//! SchemaInfo
const std = @import("std");

pub const SchemaInfo = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) SchemaInfo { return .{ .allocator = allocator }; }
    pub fn deinit(self: *SchemaInfo) void { _ = self; }
};

test "SchemaInfo" {
    const allocator = std.testing.allocator;
    var instance = SchemaInfo.init(allocator);
    defer instance.deinit();
}
