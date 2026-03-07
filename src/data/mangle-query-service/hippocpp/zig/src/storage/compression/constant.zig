//! Constant
const std = @import("std");

pub const Constant = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Constant {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Constant) void {
        _ = self;
    }
};

test "Constant" {
    const allocator = std.testing.allocator;
    var instance = Constant.init(allocator);
    defer instance.deinit();
}
