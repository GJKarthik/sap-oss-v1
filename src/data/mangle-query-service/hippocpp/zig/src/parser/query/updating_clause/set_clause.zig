//! SetClauseParsed
const std = @import("std");

pub const SetClauseParsed = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) SetClauseParsed { return .{ .allocator = allocator }; }
    pub fn deinit(self: *SetClauseParsed) void { _ = self; }
};

test "SetClauseParsed" {
    const allocator = std.testing.allocator;
    var instance = SetClauseParsed.init(allocator);
    defer instance.deinit();
}
