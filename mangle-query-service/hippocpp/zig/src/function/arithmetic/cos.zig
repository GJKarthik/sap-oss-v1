//! CosFunction
const std = @import("std");

pub const CosFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) CosFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *CosFunction) void {
        _ = self;
    }
};

test "CosFunction" {
    const allocator = std.testing.allocator;
    var instance = CosFunction.init(allocator);
    defer instance.deinit();
}
