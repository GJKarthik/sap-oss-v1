//! LiteralEvaluator
const std = @import("std");

pub const LiteralEvaluator = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LiteralEvaluator {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LiteralEvaluator) void {
        _ = self;
    }
};

test "LiteralEvaluator" {
    const allocator = std.testing.allocator;
    var instance = LiteralEvaluator.init(allocator);
    defer instance.deinit();
}
