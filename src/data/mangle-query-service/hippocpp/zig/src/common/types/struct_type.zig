//! StructType
const std = @import("std");

pub const StructType = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) StructType {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *StructType) void {
        _ = self;
    }
};

test "StructType" {
    const allocator = std.testing.allocator;
    var instance = StructType.init(allocator);
    defer instance.deinit();
}
