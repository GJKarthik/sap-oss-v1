//! PipelineFinishOp
const std = @import("std");

pub const PipelineFinishOp = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PipelineFinishOp { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PipelineFinishOp) void { _ = self; }
};

test "PipelineFinishOp" {
    const allocator = std.testing.allocator;
    var instance = PipelineFinishOp.init(allocator);
    defer instance.deinit();
}
