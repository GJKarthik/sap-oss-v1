//! LogicalScan
const std = @import("std");

pub const LogicalScan = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LogicalScan {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LogicalScan) void {
        _ = self;
    }
};

test "LogicalScan" {
    const allocator = std.testing.allocator;
    var instance = LogicalScan.init(allocator);
    defer instance.deinit();
}
