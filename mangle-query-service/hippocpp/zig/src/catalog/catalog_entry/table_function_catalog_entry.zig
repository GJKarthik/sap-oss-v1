//! TableFunctionCatalogEntry
const std = @import("std");

pub const TableFunctionCatalogEntry = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TableFunctionCatalogEntry {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *TableFunctionCatalogEntry) void {
        _ = self;
    }
};

test "TableFunctionCatalogEntry" {
    const allocator = std.testing.allocator;
    var instance = TableFunctionCatalogEntry.init(allocator);
    defer instance.deinit();
}
