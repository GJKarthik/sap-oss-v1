//! TableCatalogEntry
const std = @import("std");

pub const TableCatalogEntry = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TableCatalogEntry {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *TableCatalogEntry) void {
        _ = self;
    }
};

test "TableCatalogEntry" {
    const allocator = std.testing.allocator;
    var instance = TableCatalogEntry.init(allocator);
    defer instance.deinit();
}
