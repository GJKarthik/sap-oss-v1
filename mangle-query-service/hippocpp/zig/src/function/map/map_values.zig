//! MapValuesFunction
const std = @import("std");

pub const MapValuesFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MapValuesFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *MapValuesFunction) void {
        _ = self;
    }
};

test "MapValuesFunction" {
    const allocator = std.testing.allocator;
    var instance = MapValuesFunction.init(allocator);
    defer instance.deinit();
}
