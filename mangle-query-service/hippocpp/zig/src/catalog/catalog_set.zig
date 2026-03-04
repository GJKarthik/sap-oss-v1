//! CatalogSet
const std = @import("std");

pub const CatalogSet = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) CatalogSet {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *CatalogSet) void {
        _ = self;
    }
};

test "CatalogSet" {
    const allocator = std.testing.allocator;
    var instance = CatalogSet.init(allocator);
    defer instance.deinit();
}
