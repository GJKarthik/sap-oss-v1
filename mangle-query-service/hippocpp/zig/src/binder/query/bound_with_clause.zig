//! BoundWithClause
const std = @import("std");

pub const BoundWithClause = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BoundWithClause {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BoundWithClause) void {
        _ = self;
    }
};

test "BoundWithClause" {
    const allocator = std.testing.allocator;
    var instance = BoundWithClause.init(allocator);
    defer instance.deinit();
}
