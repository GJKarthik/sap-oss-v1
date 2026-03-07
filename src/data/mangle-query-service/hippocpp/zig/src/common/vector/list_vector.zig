//! ListVector
const std = @import("std");

pub const ListVector = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ListVector {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ListVector) void {
        _ = self;
    }
};

test "ListVector" {
    const allocator = std.testing.allocator;
    var instance = ListVector.init(allocator);
    defer instance.deinit();
}
