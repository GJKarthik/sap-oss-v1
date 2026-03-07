//! AttachDatabase
const std = @import("std");

pub const AttachDatabase = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AttachDatabase {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AttachDatabase) void {
        _ = self;
    }
};

test "AttachDatabase" {
    const allocator = std.testing.allocator;
    var instance = AttachDatabase.init(allocator);
    defer instance.deinit();
}
