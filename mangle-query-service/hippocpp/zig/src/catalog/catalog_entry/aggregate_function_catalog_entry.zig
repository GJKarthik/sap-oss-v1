//! AggregateFunctionCatalogEntry
const std = @import("std");

pub const AggregateFunctionCatalogEntry = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AggregateFunctionCatalogEntry {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AggregateFunctionCatalogEntry) void {
        _ = self;
    }
};

test "AggregateFunctionCatalogEntry" {
    const allocator = std.testing.allocator;
    var instance = AggregateFunctionCatalogEntry.init(allocator);
    defer instance.deinit();
}
