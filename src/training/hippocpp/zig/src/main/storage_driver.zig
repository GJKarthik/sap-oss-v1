//! Storage driver abstraction at main module boundary.

const std = @import("std");

pub const StorageDriver = struct {
    allocator: std.mem.Allocator,
    base_path: []u8,

    pub fn init(allocator: std.mem.Allocator, base_path: []const u8) !StorageDriver {
        return .{
            .allocator = allocator,
            .base_path = try allocator.dupe(u8, base_path),
        };
    }

    pub fn deinit(self: *StorageDriver) void {
        self.allocator.free(self.base_path);
    }

    pub fn ensureBasePath(self: *const StorageDriver) !void {
        if (std.mem.eql(u8, self.base_path, ":memory:")) return;
        try std.fs.cwd().makePath(self.base_path);
    }
};

test "storage driver path setup" {
    const allocator = std.testing.allocator;
    var driver = try StorageDriver.init(allocator, ":memory:");
    defer driver.deinit(std.testing.allocator);

    try driver.ensureBasePath();
}
