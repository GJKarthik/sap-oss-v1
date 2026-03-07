//! Set
const std = @import("std");

pub const Set = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Set {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Set) void {
        _ = self;
    }
};

test "Set" {
    const allocator = std.testing.allocator;
    var instance = Set.init(allocator);
    defer instance.deinit();
}
