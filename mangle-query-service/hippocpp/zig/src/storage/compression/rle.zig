//! RLE
const std = @import("std");

pub const RLE = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) RLE {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *RLE) void {
        _ = self;
    }
};

test "RLE" {
    const allocator = std.testing.allocator;
    var instance = RLE.init(allocator);
    defer instance.deinit();
}
