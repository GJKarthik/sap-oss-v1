//! GenericScan
const std = @import("std");

pub const GenericScan = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) GenericScan {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *GenericScan) void {
        _ = self;
    }
};

test "GenericScan" {
    const allocator = std.testing.allocator;
    var instance = GenericScan.init(allocator);
    defer instance.deinit();
}
