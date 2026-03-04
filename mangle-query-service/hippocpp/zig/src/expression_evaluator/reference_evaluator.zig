//! ReferenceEvaluator
const std = @import("std");

pub const ReferenceEvaluator = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ReferenceEvaluator {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ReferenceEvaluator) void {
        _ = self;
    }
};

test "ReferenceEvaluator" {
    const allocator = std.testing.allocator;
    var instance = ReferenceEvaluator.init(allocator);
    defer instance.deinit();
}
