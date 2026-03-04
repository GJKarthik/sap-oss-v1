//! Uncompressed
const std = @import("std");

pub const Uncompressed = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Uncompressed {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Uncompressed) void {
        _ = self;
    }
};

test "Uncompressed" {
    const allocator = std.testing.allocator;
    var instance = Uncompressed.init(allocator);
    defer instance.deinit();
}
