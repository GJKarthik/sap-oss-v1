//! RemoveFactorization
const std = @import("std");

pub const RemoveFactorization = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) RemoveFactorization {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *RemoveFactorization) void {
        _ = self;
    }
};

test "RemoveFactorization" {
    const allocator = std.testing.allocator;
    var instance = RemoveFactorization.init(allocator);
    defer instance.deinit();
}
