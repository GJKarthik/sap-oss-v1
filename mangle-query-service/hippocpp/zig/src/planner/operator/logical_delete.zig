//! LogicalDelete
const std = @import("std");

pub const LogicalDelete = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LogicalDelete {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LogicalDelete) void {
        _ = self;
    }
};

test "LogicalDelete" {
    const allocator = std.testing.allocator;
    var instance = LogicalDelete.init(allocator);
    defer instance.deinit();
}
