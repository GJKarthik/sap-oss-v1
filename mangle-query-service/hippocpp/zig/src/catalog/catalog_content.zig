//! CatalogContent
const std = @import("std");

pub const CatalogContent = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) CatalogContent {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *CatalogContent) void {
        _ = self;
    }
};

test "CatalogContent" {
    const allocator = std.testing.allocator;
    var instance = CatalogContent.init(allocator);
    defer instance.deinit();
}
