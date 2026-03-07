//! TimestampTZ
const std = @import("std");

pub const TimestampTZ = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TimestampTZ {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *TimestampTZ) void {
        _ = self;
    }
};

test "TimestampTZ" {
    const allocator = std.testing.allocator;
    var instance = TimestampTZ.init(allocator);
    defer instance.deinit();
}
