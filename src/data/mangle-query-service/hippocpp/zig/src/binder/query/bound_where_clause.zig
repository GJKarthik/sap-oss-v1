//! BoundWhereClause
const std = @import("std");

pub const BoundWhereClause = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BoundWhereClause {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BoundWhereClause) void {
        _ = self;
    }
};

test "BoundWhereClause" {
    const allocator = std.testing.allocator;
    var instance = BoundWhereClause.init(allocator);
    defer instance.deinit();
}
