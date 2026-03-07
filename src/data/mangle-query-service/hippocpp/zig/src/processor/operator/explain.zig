//! Explain
const std = @import("std");

pub const Explain = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Explain {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Explain) void {
        _ = self;
    }
};

test "Explain" {
    const allocator = std.testing.allocator;
    var instance = Explain.init(allocator);
    defer instance.deinit();
}
