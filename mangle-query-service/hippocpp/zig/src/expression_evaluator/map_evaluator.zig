//! MapEvaluator
const std = @import("std");

pub const MapEvaluator = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MapEvaluator {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *MapEvaluator) void {
        _ = self;
    }
};

test "MapEvaluator" {
    const allocator = std.testing.allocator;
    var instance = MapEvaluator.init(allocator);
    defer instance.deinit();
}
