//! KuList
const std = @import("std");

pub const KuList = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) KuList {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *KuList) void {
        _ = self;
    }
};

test "KuList" {
    const allocator = std.testing.allocator;
    var instance = KuList.init(allocator);
    defer instance.deinit();
}
