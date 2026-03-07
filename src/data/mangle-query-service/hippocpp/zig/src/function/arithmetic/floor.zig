//! FloorFunction
const std = @import("std");

pub const FloorFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) FloorFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *FloorFunction) void {
        _ = self;
    }
};

test "FloorFunction" {
    const allocator = std.testing.allocator;
    var instance = FloorFunction.init(allocator);
    defer instance.deinit();
}
