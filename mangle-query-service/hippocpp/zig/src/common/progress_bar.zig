//! ProgressBarCommon
const std = @import("std");

pub const ProgressBarCommon = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ProgressBarCommon { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ProgressBarCommon) void { _ = self; }
};

test "ProgressBarCommon" {
    const allocator = std.testing.allocator;
    var instance = ProgressBarCommon.init(allocator);
    defer instance.deinit();
}
