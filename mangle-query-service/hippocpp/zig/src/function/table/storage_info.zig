//! StorageInfoFunction
const std = @import("std");

pub const StorageInfoFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) StorageInfoFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *StorageInfoFunction) void { _ = self; }
};

test "StorageInfoFunction" {
    const allocator = std.testing.allocator;
    var instance = StorageInfoFunction.init(allocator);
    defer instance.deinit();
}
