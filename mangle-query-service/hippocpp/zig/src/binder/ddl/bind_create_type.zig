//! BindCreateType
const std = @import("std");

pub const BindCreateType = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BindCreateType {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BindCreateType) void {
        _ = self;
    }
};

test "BindCreateType" {
    const allocator = std.testing.allocator;
    var instance = BindCreateType.init(allocator);
    defer instance.deinit();
}
