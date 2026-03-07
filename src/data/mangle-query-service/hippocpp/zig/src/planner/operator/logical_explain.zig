//! LogicalExplain
const std = @import("std");

pub const LogicalExplain = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LogicalExplain {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LogicalExplain) void {
        _ = self;
    }
};

test "LogicalExplain" {
    const allocator = std.testing.allocator;
    var instance = LogicalExplain.init(allocator);
    defer instance.deinit();
}
