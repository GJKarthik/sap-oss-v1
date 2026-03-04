//! LessEqualsFunction
const std = @import("std");

pub const LessEqualsFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LessEqualsFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LessEqualsFunction) void {
        _ = self;
    }
};

test "LessEqualsFunction" {
    const allocator = std.testing.allocator;
    var instance = LessEqualsFunction.init(allocator);
    defer instance.deinit();
}
