//! StringVector
const std = @import("std");

pub const StringVector = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) StringVector {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *StringVector) void {
        _ = self;
    }
};

test "StringVector" {
    const allocator = std.testing.allocator;
    var instance = StringVector.init(allocator);
    defer instance.deinit();
}
