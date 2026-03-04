//! ProcessorTask
const std = @import("std");

pub const ProcessorTask = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ProcessorTask { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ProcessorTask) void { _ = self; }
};

test "ProcessorTask" {
    const allocator = std.testing.allocator;
    var instance = ProcessorTask.init(allocator);
    defer instance.deinit();
}
