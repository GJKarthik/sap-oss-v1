//! BoundOrderByClause
const std = @import("std");

pub const BoundOrderByClause = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BoundOrderByClause {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BoundOrderByClause) void {
        _ = self;
    }
};

test "BoundOrderByClause" {
    const allocator = std.testing.allocator;
    var instance = BoundOrderByClause.init(allocator);
    defer instance.deinit();
}
