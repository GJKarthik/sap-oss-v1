//! SubtractFunction
const std = @import("std");

pub const SubtractFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) SubtractFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *SubtractFunction) void {
        _ = self;
    }
};

test "SubtractFunction" {
    const allocator = std.testing.allocator;
    var instance = SubtractFunction.init(allocator);
    defer instance.deinit();
}
