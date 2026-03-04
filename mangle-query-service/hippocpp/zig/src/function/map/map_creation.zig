//! MapCreationFunction
const std = @import("std");

pub const MapCreationFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MapCreationFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *MapCreationFunction) void {
        _ = self;
    }
};

test "MapCreationFunction" {
    const allocator = std.testing.allocator;
    var instance = MapCreationFunction.init(allocator);
    defer instance.deinit();
}
