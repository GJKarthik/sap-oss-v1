//! StructVector
const std = @import("std");

pub const StructVector = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) StructVector {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *StructVector) void {
        _ = self;
    }
};

test "StructVector" {
    const allocator = std.testing.allocator;
    var instance = StructVector.init(allocator);
    defer instance.deinit();
}
