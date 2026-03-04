//! ProgressBar
const std = @import("std");

pub const ProgressBar = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ProgressBar {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ProgressBar) void {
        _ = self;
    }
};

test "ProgressBar" {
    const allocator = std.testing.allocator;
    var instance = ProgressBar.init(allocator);
    defer instance.deinit();
}
