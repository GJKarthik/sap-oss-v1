//! ExtensionStatement
const std = @import("std");

pub const ExtensionStatement = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ExtensionStatement {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ExtensionStatement) void {
        _ = self;
    }
};

test "ExtensionStatement" {
    const allocator = std.testing.allocator;
    var instance = ExtensionStatement.init(allocator);
    defer instance.deinit();
}
