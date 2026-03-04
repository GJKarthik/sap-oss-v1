//! SubqueryEvaluator
const std = @import("std");

pub const SubqueryEvaluator = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) SubqueryEvaluator {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *SubqueryEvaluator) void {
        _ = self;
    }
};

test "SubqueryEvaluator" {
    const allocator = std.testing.allocator;
    var instance = SubqueryEvaluator.init(allocator);
    defer instance.deinit();
}
