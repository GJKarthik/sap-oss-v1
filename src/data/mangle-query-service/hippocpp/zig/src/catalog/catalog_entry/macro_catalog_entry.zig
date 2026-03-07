//! MacroCatalogEntry
const std = @import("std");

pub const MacroCatalogEntry = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) MacroCatalogEntry { return .{ .allocator = allocator }; }
    pub fn deinit(self: *MacroCatalogEntry) void { _ = self; }
};

test "MacroCatalogEntry" {
    const allocator = std.testing.allocator;
    var instance = MacroCatalogEntry.init(allocator);
    defer instance.deinit();
}
