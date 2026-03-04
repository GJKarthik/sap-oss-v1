//! RelGroupCatalogEntry
const std = @import("std");

pub const RelGroupCatalogEntry = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) RelGroupCatalogEntry {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *RelGroupCatalogEntry) void {
        _ = self;
    }
};

test "RelGroupCatalogEntry" {
    const allocator = std.testing.allocator;
    var instance = RelGroupCatalogEntry.init(allocator);
    defer instance.deinit();
}
