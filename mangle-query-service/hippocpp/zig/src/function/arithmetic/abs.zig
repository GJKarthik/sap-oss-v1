//! AbsFunction
const std = @import("std");

pub const AbsFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AbsFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AbsFunction) void {
        _ = self;
    }
};

test "AbsFunction" {
    const allocator = std.testing.allocator;
    var instance = AbsFunction.init(allocator);
    defer instance.deinit();
}
