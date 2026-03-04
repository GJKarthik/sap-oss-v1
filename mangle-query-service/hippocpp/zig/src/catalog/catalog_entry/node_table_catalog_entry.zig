//! NodeTableCatalogEntry
const std = @import("std");

pub const NodeTableCatalogEntry = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) NodeTableCatalogEntry {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *NodeTableCatalogEntry) void {
        _ = self;
    }
};

test "NodeTableCatalogEntry" {
    const allocator = std.testing.allocator;
    var instance = NodeTableCatalogEntry.init(allocator);
    defer instance.deinit();
}
