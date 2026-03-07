//! ValueVector
const std = @import("std");

pub const ValueVector = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ValueVector {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ValueVector) void {
        _ = self;
    }
};

test "ValueVector" {
    const allocator = std.testing.allocator;
    var instance = ValueVector.init(allocator);
    defer instance.deinit();
}
