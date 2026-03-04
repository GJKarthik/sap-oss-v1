//! CeilFunction
const std = @import("std");

pub const CeilFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) CeilFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *CeilFunction) void {
        _ = self;
    }
};

test "CeilFunction" {
    const allocator = std.testing.allocator;
    var instance = CeilFunction.init(allocator);
    defer instance.deinit();
}
