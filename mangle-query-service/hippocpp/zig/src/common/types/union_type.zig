//! UnionType
const std = @import("std");

pub const UnionType = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) UnionType {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *UnionType) void {
        _ = self;
    }
};

test "UnionType" {
    const allocator = std.testing.allocator;
    var instance = UnionType.init(allocator);
    defer instance.deinit();
}
