//! LogicalUnwind
const std = @import("std");

pub const LogicalUnwind = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LogicalUnwind {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LogicalUnwind) void {
        _ = self;
    }
};

test "LogicalUnwind" {
    const allocator = std.testing.allocator;
    var instance = LogicalUnwind.init(allocator);
    defer instance.deinit();
}
