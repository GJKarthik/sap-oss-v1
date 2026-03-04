//! RelTableCatalogEntry
const std = @import("std");

pub const RelTableCatalogEntry = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) RelTableCatalogEntry {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *RelTableCatalogEntry) void {
        _ = self;
    }
};

test "RelTableCatalogEntry" {
    const allocator = std.testing.allocator;
    var instance = RelTableCatalogEntry.init(allocator);
    defer instance.deinit();
}
