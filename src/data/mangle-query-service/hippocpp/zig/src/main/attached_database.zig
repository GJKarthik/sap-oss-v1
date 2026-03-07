//! AttachedDatabase
const std = @import("std");

pub const AttachedDatabase = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AttachedDatabase {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AttachedDatabase) void {
        _ = self;
    }
};

test "AttachedDatabase" {
    const allocator = std.testing.allocator;
    var instance = AttachedDatabase.init(allocator);
    defer instance.deinit();
}
