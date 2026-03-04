//! MarkScan
const std = @import("std");

pub const MarkScan = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MarkScan {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *MarkScan) void {
        _ = self;
    }
};

test "MarkScan" {
    const allocator = std.testing.allocator;
    var instance = MarkScan.init(allocator);
    defer instance.deinit();
}
