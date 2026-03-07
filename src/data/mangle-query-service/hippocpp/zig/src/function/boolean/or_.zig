//! OrFunction
const std = @import("std");

pub const OrFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) OrFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *OrFunction) void {
        _ = self;
    }
};

test "OrFunction" {
    const allocator = std.testing.allocator;
    var instance = OrFunction.init(allocator);
    defer instance.deinit();
}
