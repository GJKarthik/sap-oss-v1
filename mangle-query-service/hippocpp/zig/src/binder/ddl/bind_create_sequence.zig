//! BindCreateSequence
const std = @import("std");

pub const BindCreateSequence = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BindCreateSequence {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BindCreateSequence) void {
        _ = self;
    }
};

test "BindCreateSequence" {
    const allocator = std.testing.allocator;
    var instance = BindCreateSequence.init(allocator);
    defer instance.deinit();
}
