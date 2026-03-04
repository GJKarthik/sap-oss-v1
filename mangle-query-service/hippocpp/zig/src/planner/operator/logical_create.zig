//! LogicalCreate
const std = @import("std");

pub const LogicalCreate = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LogicalCreate {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LogicalCreate) void {
        _ = self;
    }
};

test "LogicalCreate" {
    const allocator = std.testing.allocator;
    var instance = LogicalCreate.init(allocator);
    defer instance.deinit();
}
