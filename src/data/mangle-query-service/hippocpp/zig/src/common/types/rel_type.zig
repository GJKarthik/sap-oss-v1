//! RelType
const std = @import("std");

pub const RelType = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) RelType {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *RelType) void {
        _ = self;
    }
};

test "RelType" {
    const allocator = std.testing.allocator;
    var instance = RelType.init(allocator);
    defer instance.deinit();
}
