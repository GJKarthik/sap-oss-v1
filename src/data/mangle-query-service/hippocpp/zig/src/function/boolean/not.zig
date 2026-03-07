//! NotFunction
const std = @import("std");

pub const NotFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) NotFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *NotFunction) void {
        _ = self;
    }
};

test "NotFunction" {
    const allocator = std.testing.allocator;
    var instance = NotFunction.init(allocator);
    defer instance.deinit();
}
