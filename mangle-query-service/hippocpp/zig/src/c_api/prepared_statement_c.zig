//! PreparedStatementC
const std = @import("std");

pub const PreparedStatementC = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) PreparedStatementC {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *PreparedStatementC) void {
        _ = self;
    }
};

test "PreparedStatementC" {
    const allocator = std.testing.allocator;
    var instance = PreparedStatementC.init(allocator);
    defer instance.deinit();
}
