//! Property
const std = @import("std");

pub const Property = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Property {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Property) void {
        _ = self;
    }
};

test "Property" {
    const allocator = std.testing.allocator;
    var instance = Property.init(allocator);
    defer instance.deinit();
}
