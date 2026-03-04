//! PropertyCollector
const std = @import("std");

pub const PropertyCollector = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) PropertyCollector {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *PropertyCollector) void {
        _ = self;
    }
};

test "PropertyCollector" {
    const allocator = std.testing.allocator;
    var instance = PropertyCollector.init(allocator);
    defer instance.deinit();
}
