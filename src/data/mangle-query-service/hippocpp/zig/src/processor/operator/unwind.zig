//! Unwind
const std = @import("std");

pub const Unwind = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Unwind {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Unwind) void {
        _ = self;
    }
};

test "Unwind" {
    const allocator = std.testing.allocator;
    var instance = Unwind.init(allocator);
    defer instance.deinit();
}
