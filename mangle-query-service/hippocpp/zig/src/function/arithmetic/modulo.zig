//! ModuloFunction
const std = @import("std");

pub const ModuloFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ModuloFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ModuloFunction) void {
        _ = self;
    }
};

test "ModuloFunction" {
    const allocator = std.testing.allocator;
    var instance = ModuloFunction.init(allocator);
    defer instance.deinit();
}
