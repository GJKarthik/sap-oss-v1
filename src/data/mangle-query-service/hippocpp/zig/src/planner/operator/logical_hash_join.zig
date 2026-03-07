//! LogicalHashJoin
const std = @import("std");

pub const LogicalHashJoin = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LogicalHashJoin {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LogicalHashJoin) void {
        _ = self;
    }
};

test "LogicalHashJoin" {
    const allocator = std.testing.allocator;
    var instance = LogicalHashJoin.init(allocator);
    defer instance.deinit();
}
