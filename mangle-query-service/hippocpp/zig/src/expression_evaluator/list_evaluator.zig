//! ListEvaluator
const std = @import("std");

pub const ListEvaluator = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ListEvaluator {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ListEvaluator) void {
        _ = self;
    }
};

test "ListEvaluator" {
    const allocator = std.testing.allocator;
    var instance = ListEvaluator.init(allocator);
    defer instance.deinit();
}
