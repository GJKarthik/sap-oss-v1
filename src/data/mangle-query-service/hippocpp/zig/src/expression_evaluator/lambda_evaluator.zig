//! LambdaEvaluator
const std = @import("std");

pub const LambdaEvaluator = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LambdaEvaluator {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LambdaEvaluator) void {
        _ = self;
    }
};

test "LambdaEvaluator" {
    const allocator = std.testing.allocator;
    var instance = LambdaEvaluator.init(allocator);
    defer instance.deinit();
}
