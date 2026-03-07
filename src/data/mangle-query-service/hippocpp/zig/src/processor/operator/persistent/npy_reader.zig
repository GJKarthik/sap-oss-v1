//! NPYReader
const std = @import("std");

pub const NPYReader = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) NPYReader { return .{ .allocator = allocator }; }
    pub fn deinit(self: *NPYReader) void { _ = self; }
};

test "NPYReader" {
    const allocator = std.testing.allocator;
    var instance = NPYReader.init(allocator);
    defer instance.deinit();
}
