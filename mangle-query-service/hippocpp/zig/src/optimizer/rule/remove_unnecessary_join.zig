//! RemoveUnnecessaryJoin
const std = @import("std");

pub const RemoveUnnecessaryJoin = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) RemoveUnnecessaryJoin {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *RemoveUnnecessaryJoin) void {
        _ = self;
    }
};

test "RemoveUnnecessaryJoin" {
    const allocator = std.testing.allocator;
    var instance = RemoveUnnecessaryJoin.init(allocator);
    defer instance.deinit();
}
