//! FlattenRule
const std = @import("std");

pub const FlattenRule = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) FlattenRule {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *FlattenRule) void {
        _ = self;
    }
};

test "FlattenRule" {
    const allocator = std.testing.allocator;
    var instance = FlattenRule.init(allocator);
    defer instance.deinit();
}
