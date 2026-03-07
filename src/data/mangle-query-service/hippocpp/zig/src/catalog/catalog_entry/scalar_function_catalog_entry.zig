//! ScalarFunctionCatalogEntry
const std = @import("std");

pub const ScalarFunctionCatalogEntry = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ScalarFunctionCatalogEntry {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ScalarFunctionCatalogEntry) void {
        _ = self;
    }
};

test "ScalarFunctionCatalogEntry" {
    const allocator = std.testing.allocator;
    var instance = ScalarFunctionCatalogEntry.init(allocator);
    defer instance.deinit();
}
