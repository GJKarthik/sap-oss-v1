//! HashJoinBuild
const std = @import("std");

pub const HashJoinBuild = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) HashJoinBuild {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *HashJoinBuild) void {
        _ = self;
    }
};

test "HashJoinBuild" {
    const allocator = std.testing.allocator;
    var instance = HashJoinBuild.init(allocator);
    defer instance.deinit();
}
