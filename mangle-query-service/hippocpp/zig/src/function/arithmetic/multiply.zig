//! MultiplyFunction
const std = @import("std");

pub const MultiplyFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MultiplyFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *MultiplyFunction) void {
        _ = self;
    }
};

test "MultiplyFunction" {
    const allocator = std.testing.allocator;
    var instance = MultiplyFunction.init(allocator);
    defer instance.deinit();
}
