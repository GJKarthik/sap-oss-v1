//! RecursiveRelType
const std = @import("std");

pub const RecursiveRelType = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) RecursiveRelType {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *RecursiveRelType) void {
        _ = self;
    }
};

test "RecursiveRelType" {
    const allocator = std.testing.allocator;
    var instance = RecursiveRelType.init(allocator);
    defer instance.deinit();
}
