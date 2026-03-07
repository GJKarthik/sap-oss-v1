//! ViewCatalogEntry
const std = @import("std");

pub const ViewCatalogEntry = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ViewCatalogEntry { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ViewCatalogEntry) void { _ = self; }
};

test "ViewCatalogEntry" {
    const allocator = std.testing.allocator;
    var instance = ViewCatalogEntry.init(allocator);
    defer instance.deinit();
}
