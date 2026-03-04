//! JSONExtension
const std = @import("std");

pub const JSONExtension = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) JSONExtension {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *JSONExtension) void {
        _ = self;
    }
};

test "JSONExtension" {
    const allocator = std.testing.allocator;
    var instance = JSONExtension.init(allocator);
    defer instance.deinit();
}
