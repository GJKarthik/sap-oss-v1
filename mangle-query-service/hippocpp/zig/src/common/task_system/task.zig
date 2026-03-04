//! Task
const std = @import("std");

pub const Task = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Task {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Task) void {
        _ = self;
    }
};

test "Task" {
    const allocator = std.testing.allocator;
    var instance = Task.init(allocator);
    defer instance.deinit();
}
