//! IndexCatalogEntry
const std = @import("std");

pub const IndexCatalogEntry = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) IndexCatalogEntry { return .{ .allocator = allocator }; }
    pub fn deinit(self: *IndexCatalogEntry) void { _ = self; }
};

test "IndexCatalogEntry" {
    const allocator = std.testing.allocator;
    var instance = IndexCatalogEntry.init(allocator);
    defer instance.deinit();
}
