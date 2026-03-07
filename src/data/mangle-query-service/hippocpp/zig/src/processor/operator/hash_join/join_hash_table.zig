//! JoinHashTable
const std = @import("std");

pub const JoinHashTable = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) JoinHashTable {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *JoinHashTable) void {
        _ = self;
    }
};

test "JoinHashTable" {
    const allocator = std.testing.allocator;
    var instance = JoinHashTable.init(allocator);
    defer instance.deinit();
}
