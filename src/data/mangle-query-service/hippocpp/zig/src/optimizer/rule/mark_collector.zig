//! MarkCollector
const std = @import("std");

pub const MarkCollector = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MarkCollector {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *MarkCollector) void {
        _ = self;
    }
};

test "MarkCollector" {
    const allocator = std.testing.allocator;
    var instance = MarkCollector.init(allocator);
    defer instance.deinit();
}
