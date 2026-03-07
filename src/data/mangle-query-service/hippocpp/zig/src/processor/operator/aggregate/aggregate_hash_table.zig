//! AggregateHashTable
const std = @import("std");

pub const AggregateHashTable = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AggregateHashTable {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AggregateHashTable) void {
        _ = self;
    }
};

test "AggregateHashTable" {
    const allocator = std.testing.allocator;
    var instance = AggregateHashTable.init(allocator);
    defer instance.deinit();
}
