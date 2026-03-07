//! MergeClauseParsed
const std = @import("std");

pub const MergeClauseParsed = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) MergeClauseParsed { return .{ .allocator = allocator }; }
    pub fn deinit(self: *MergeClauseParsed) void { _ = self; }
};

test "MergeClauseParsed" {
    const allocator = std.testing.allocator;
    var instance = MergeClauseParsed.init(allocator);
    defer instance.deinit();
}
