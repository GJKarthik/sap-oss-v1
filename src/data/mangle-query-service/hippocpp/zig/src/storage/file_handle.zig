//! FileHandle
const std = @import("std");

pub const FileHandle = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) FileHandle { return .{ .allocator = allocator }; }
    pub fn deinit(self: *FileHandle) void { _ = self; }
};

test "FileHandle" {
    const allocator = std.testing.allocator;
    var instance = FileHandle.init(allocator);
    defer instance.deinit();
}
