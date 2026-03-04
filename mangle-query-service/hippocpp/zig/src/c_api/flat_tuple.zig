//! FlatTuple
const std = @import("std");

pub const FlatTuple = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) FlatTuple {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *FlatTuple) void {
        _ = self;
    }
};

test "FlatTuple" {
    const allocator = std.testing.allocator;
    var instance = FlatTuple.init(allocator);
    defer instance.deinit();
}
