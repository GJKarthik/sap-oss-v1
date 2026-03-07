//! DatePartFunction
const std = @import("std");

pub const DatePartFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) DatePartFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *DatePartFunction) void {
        _ = self;
    }
};

test "DatePartFunction" {
    const allocator = std.testing.allocator;
    var instance = DatePartFunction.init(allocator);
    defer instance.deinit();
}
