//! TypeCatalogEntry
const std = @import("std");

pub const TypeCatalogEntry = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TypeCatalogEntry {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *TypeCatalogEntry) void {
        _ = self;
    }
};

test "TypeCatalogEntry" {
    const allocator = std.testing.allocator;
    var instance = TypeCatalogEntry.init(allocator);
    defer instance.deinit();
}
