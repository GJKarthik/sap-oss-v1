//! StorageStructure
const std = @import("std");

pub const StorageStructure = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) StorageStructure { return .{ .allocator = allocator }; }
    pub fn deinit(self: *StorageStructure) void { _ = self; }
};

test "StorageStructure" {
    const allocator = std.testing.allocator;
    var instance = StorageStructure.init(allocator);
    defer instance.deinit();
}
