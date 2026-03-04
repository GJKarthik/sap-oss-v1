//! FileInfo
const std = @import("std");

pub const FileInfo = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) FileInfo {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *FileInfo) void {
        _ = self;
    }
};

test "FileInfo" {
    const allocator = std.testing.allocator;
    var instance = FileInfo.init(allocator);
    defer instance.deinit();
}
