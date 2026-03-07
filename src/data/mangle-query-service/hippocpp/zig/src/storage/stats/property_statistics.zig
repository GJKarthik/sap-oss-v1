//! PropertyStatistics
const std = @import("std");

pub const PropertyStatistics = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) PropertyStatistics {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *PropertyStatistics) void {
        _ = self;
    }
};

test "PropertyStatistics" {
    const allocator = std.testing.allocator;
    var instance = PropertyStatistics.init(allocator);
    defer instance.deinit();
}
