//! KuString
const std = @import("std");

pub const KuString = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) KuString {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *KuString) void {
        _ = self;
    }
};

test "KuString" {
    const allocator = std.testing.allocator;
    var instance = KuString.init(allocator);
    defer instance.deinit();
}
