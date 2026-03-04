//! Except
const std = @import("std");

pub const Except = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Except {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Except) void {
        _ = self;
    }
};

test "Except" {
    const allocator = std.testing.allocator;
    var instance = Except.init(allocator);
    defer instance.deinit();
}
