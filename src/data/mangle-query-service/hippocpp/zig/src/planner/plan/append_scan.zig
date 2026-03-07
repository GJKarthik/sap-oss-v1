//! AppendScan
const std = @import("std");

pub const AppendScan = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AppendScan {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AppendScan) void {
        _ = self;
    }
};

test "AppendScan" {
    const allocator = std.testing.allocator;
    var instance = AppendScan.init(allocator);
    defer instance.deinit();
}
