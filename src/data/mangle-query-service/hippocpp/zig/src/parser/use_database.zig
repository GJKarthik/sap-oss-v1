//! UseDatabase
const std = @import("std");

pub const UseDatabase = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) UseDatabase {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *UseDatabase) void {
        _ = self;
    }
};

test "UseDatabase" {
    const allocator = std.testing.allocator;
    var instance = UseDatabase.init(allocator);
    defer instance.deinit();
}
