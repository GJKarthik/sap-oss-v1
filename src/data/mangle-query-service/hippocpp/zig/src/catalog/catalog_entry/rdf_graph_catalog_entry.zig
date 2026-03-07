//! RDFGraphCatalogEntry
const std = @import("std");

pub const RDFGraphCatalogEntry = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) RDFGraphCatalogEntry {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *RDFGraphCatalogEntry) void {
        _ = self;
    }
};

test "RDFGraphCatalogEntry" {
    const allocator = std.testing.allocator;
    var instance = RDFGraphCatalogEntry.init(allocator);
    defer instance.deinit();
}
