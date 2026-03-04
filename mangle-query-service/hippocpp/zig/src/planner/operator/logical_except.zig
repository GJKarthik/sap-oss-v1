//! LogicalExcept
const std = @import("std");

pub const LogicalExcept = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LogicalExcept {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LogicalExcept) void {
        _ = self;
    }
};

test "LogicalExcept" {
    const allocator = std.testing.allocator;
    var instance = LogicalExcept.init(allocator);
    defer instance.deinit();
}
