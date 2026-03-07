//! BoundMatchClause
const std = @import("std");

pub const BoundMatchClause = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BoundMatchClause {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BoundMatchClause) void {
        _ = self;
    }
};

test "BoundMatchClause" {
    const allocator = std.testing.allocator;
    var instance = BoundMatchClause.init(allocator);
    defer instance.deinit();
}
