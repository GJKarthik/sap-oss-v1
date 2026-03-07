//! Connection
const std = @import("std");

pub const Connection = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Connection {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Connection) void {
        _ = self;
    }
};

test "Connection" {
    const allocator = std.testing.allocator;
    var instance = Connection.init(allocator);
    defer instance.deinit();
}
