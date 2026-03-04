//! AppendProjection
const std = @import("std");

pub const AppendProjection = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AppendProjection {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AppendProjection) void {
        _ = self;
    }
};

test "AppendProjection" {
    const allocator = std.testing.allocator;
    var instance = AppendProjection.init(allocator);
    defer instance.deinit();
}
