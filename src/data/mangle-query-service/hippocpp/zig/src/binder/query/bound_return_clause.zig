//! BoundReturnClause
const std = @import("std");

pub const BoundReturnClause = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BoundReturnClause {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BoundReturnClause) void {
        _ = self;
    }
};

test "BoundReturnClause" {
    const allocator = std.testing.allocator;
    var instance = BoundReturnClause.init(allocator);
    defer instance.deinit();
}
