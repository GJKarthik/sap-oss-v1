//! DetachDatabase
const std = @import("std");

pub const DetachDatabase = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) DetachDatabase {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *DetachDatabase) void {
        _ = self;
    }
};

test "DetachDatabase" {
    const allocator = std.testing.allocator;
    var instance = DetachDatabase.init(allocator);
    defer instance.deinit();
}
