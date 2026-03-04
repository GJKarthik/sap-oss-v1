//! HTTPFSExtension
const std = @import("std");

pub const HTTPFSExtension = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) HTTPFSExtension {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *HTTPFSExtension) void {
        _ = self;
    }
};

test "HTTPFSExtension" {
    const allocator = std.testing.allocator;
    var instance = HTTPFSExtension.init(allocator);
    defer instance.deinit();
}
