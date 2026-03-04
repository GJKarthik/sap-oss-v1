//! QueryPlanner
const std = @import("std");

pub const QueryPlanner = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) QueryPlanner {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *QueryPlanner) void {
        _ = self;
    }
};

test "QueryPlanner" {
    const allocator = std.testing.allocator;
    var instance = QueryPlanner.init(allocator);
    defer instance.deinit();
}
