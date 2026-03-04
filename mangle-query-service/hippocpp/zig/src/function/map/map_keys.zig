//! MapKeysFunction
const std = @import("std");

pub const MapKeysFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MapKeysFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *MapKeysFunction) void {
        _ = self;
    }
};

test "MapKeysFunction" {
    const allocator = std.testing.allocator;
    var instance = MapKeysFunction.init(allocator);
    defer instance.deinit();
}
