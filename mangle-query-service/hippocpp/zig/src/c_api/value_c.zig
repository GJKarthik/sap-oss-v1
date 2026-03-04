//! ValueC
const std = @import("std");

pub const ValueC = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ValueC {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ValueC) void {
        _ = self;
    }
};

test "ValueC" {
    const allocator = std.testing.allocator;
    var instance = ValueC.init(allocator);
    defer instance.deinit();
}
