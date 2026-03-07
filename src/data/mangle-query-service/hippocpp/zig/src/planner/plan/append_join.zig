//! AppendJoin
const std = @import("std");

pub const AppendJoin = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AppendJoin {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AppendJoin) void {
        _ = self;
    }
};

test "AppendJoin" {
    const allocator = std.testing.allocator;
    var instance = AppendJoin.init(allocator);
    defer instance.deinit();
}
