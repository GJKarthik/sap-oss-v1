//! DeleteClauseParsed
const std = @import("std");

pub const DeleteClauseParsed = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) DeleteClauseParsed { return .{ .allocator = allocator }; }
    pub fn deinit(self: *DeleteClauseParsed) void { _ = self; }
};

test "DeleteClauseParsed" {
    const allocator = std.testing.allocator;
    var instance = DeleteClauseParsed.init(allocator);
    defer instance.deinit();
}
