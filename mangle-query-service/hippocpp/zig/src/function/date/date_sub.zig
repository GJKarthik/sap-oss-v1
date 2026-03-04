//! DateSubFunction
const std = @import("std");

pub const DateSubFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) DateSubFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *DateSubFunction) void {
        _ = self;
    }
};

test "DateSubFunction" {
    const allocator = std.testing.allocator;
    var instance = DateSubFunction.init(allocator);
    defer instance.deinit();
}
