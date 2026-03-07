//! PortDB
const std = @import("std");

pub const PortDB = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) PortDB {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *PortDB) void {
        _ = self;
    }
};

test "PortDB" {
    const allocator = std.testing.allocator;
    var instance = PortDB.init(allocator);
    defer instance.deinit();
}
