//! StringUtils
const std = @import("std");

pub const StringUtils = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) StringUtils {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *StringUtils) void {
        _ = self;
    }
};

test "StringUtils" {
    const allocator = std.testing.allocator;
    var instance = StringUtils.init(allocator);
    defer instance.deinit();
}
