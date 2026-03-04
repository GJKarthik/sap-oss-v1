//! Merge
const std = @import("std");

pub const Merge = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Merge {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Merge) void {
        _ = self;
    }
};

test "Merge" {
    const allocator = std.testing.allocator;
    var instance = Merge.init(allocator);
    defer instance.deinit();
}
