//! OrderBy
const std = @import("std");

pub const OrderBy = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) OrderBy {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *OrderBy) void {
        _ = self;
    }
};

test "OrderBy" {
    const allocator = std.testing.allocator;
    var instance = OrderBy.init(allocator);
    defer instance.deinit();
}
