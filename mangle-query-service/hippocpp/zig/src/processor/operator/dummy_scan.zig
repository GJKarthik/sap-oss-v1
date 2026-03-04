//! DummyScan
const std = @import("std");

pub const DummyScan = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) DummyScan {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *DummyScan) void {
        _ = self;
    }
};

test "DummyScan" {
    const allocator = std.testing.allocator;
    var instance = DummyScan.init(allocator);
    defer instance.deinit();
}
