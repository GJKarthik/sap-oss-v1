//! TaskScheduler
const std = @import("std");

pub const TaskScheduler = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TaskScheduler {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *TaskScheduler) void {
        _ = self;
    }
};

test "TaskScheduler" {
    const allocator = std.testing.allocator;
    var instance = TaskScheduler.init(allocator);
    defer instance.deinit();
}
