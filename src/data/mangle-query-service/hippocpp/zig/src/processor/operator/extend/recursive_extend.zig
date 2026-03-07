//! RecursiveExtend
const std = @import("std");

pub const RecursiveExtend = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) RecursiveExtend {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *RecursiveExtend) void {
        _ = self;
    }
};

test "RecursiveExtend" {
    const allocator = std.testing.allocator;
    var instance = RecursiveExtend.init(allocator);
    defer instance.deinit();
}
