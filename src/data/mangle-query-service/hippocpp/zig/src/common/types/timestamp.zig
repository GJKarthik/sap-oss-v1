//! Timestamp
const std = @import("std");

pub const Timestamp = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Timestamp {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Timestamp) void {
        _ = self;
    }
};

test "Timestamp" {
    const allocator = std.testing.allocator;
    var instance = Timestamp.init(allocator);
    defer instance.deinit();
}
