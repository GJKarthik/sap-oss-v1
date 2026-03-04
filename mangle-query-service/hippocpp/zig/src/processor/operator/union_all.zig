//! UnionAll
const std = @import("std");

pub const UnionAll = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) UnionAll {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *UnionAll) void {
        _ = self;
    }
};

test "UnionAll" {
    const allocator = std.testing.allocator;
    var instance = UnionAll.init(allocator);
    defer instance.deinit();
}
