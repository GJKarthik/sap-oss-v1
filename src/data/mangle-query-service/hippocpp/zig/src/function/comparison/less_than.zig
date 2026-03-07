//! LessThanFunction
const std = @import("std");

pub const LessThanFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LessThanFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LessThanFunction) void {
        _ = self;
    }
};

test "LessThanFunction" {
    const allocator = std.testing.allocator;
    var instance = LessThanFunction.init(allocator);
    defer instance.deinit();
}
