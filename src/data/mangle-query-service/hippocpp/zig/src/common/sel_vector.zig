//! SelectionVector
const std = @import("std");

pub const SelectionVector = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) SelectionVector { return .{ .allocator = allocator }; }
    pub fn deinit(self: *SelectionVector) void { _ = self; }
};

test "SelectionVector" {
    const allocator = std.testing.allocator;
    var instance = SelectionVector.init(allocator);
    defer instance.deinit();
}
