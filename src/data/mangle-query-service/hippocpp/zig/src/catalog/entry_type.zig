//! EntryType
const std = @import("std");

pub const EntryType = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) EntryType { return .{ .allocator = allocator }; }
    pub fn deinit(self: *EntryType) void { _ = self; }
};

test "EntryType" {
    const allocator = std.testing.allocator;
    var instance = EntryType.init(allocator);
    defer instance.deinit();
}
