//! IndexUtils
const std = @import("std");

pub const IndexUtils = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) IndexUtils {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *IndexUtils) void {
        _ = self;
    }
};

test "IndexUtils" {
    const allocator = std.testing.allocator;
    var instance = IndexUtils.init(allocator);
    defer instance.deinit();
}
