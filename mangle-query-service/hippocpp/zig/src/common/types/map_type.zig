//! MapType
const std = @import("std");

pub const MapType = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MapType {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *MapType) void {
        _ = self;
    }
};

test "MapType" {
    const allocator = std.testing.allocator;
    var instance = MapType.init(allocator);
    defer instance.deinit();
}
