//! GDSFunctionEntry
const std = @import("std");

pub const GDSFunctionEntry = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) GDSFunctionEntry { return .{ .allocator = allocator }; }
    pub fn deinit(self: *GDSFunctionEntry) void { _ = self; }
};

test "GDSFunctionEntry" {
    const allocator = std.testing.allocator;
    var instance = GDSFunctionEntry.init(allocator);
    defer instance.deinit();
}
