//! SequenceCatalogEntry
const std = @import("std");

pub const SequenceCatalogEntry = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) SequenceCatalogEntry {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *SequenceCatalogEntry) void {
        _ = self;
    }
};

test "SequenceCatalogEntry" {
    const allocator = std.testing.allocator;
    var instance = SequenceCatalogEntry.init(allocator);
    defer instance.deinit();
}
