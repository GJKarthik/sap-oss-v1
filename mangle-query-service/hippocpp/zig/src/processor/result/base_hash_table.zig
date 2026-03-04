//! Basic hash table used by result operators.

const std = @import("std");

pub const BaseHashTable = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(u64),

    pub fn init(allocator: std.mem.Allocator) BaseHashTable {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(u64).init(allocator),
        };
    }

    pub fn deinit(self: *BaseHashTable) void {
        self.map.deinit();
    }

    pub fn increment(self: *BaseHashTable, key: []const u8) !void {
        const current = self.map.get(key) orelse 0;
        try self.map.put(key, current + 1);
    }

    pub fn get(self: *const BaseHashTable, key: []const u8) u64 {
        return self.map.get(key) orelse 0;
    }
};

test "base hash table increment" {
    const allocator = std.testing.allocator;
    var table = BaseHashTable.init(allocator);
    defer table.deinit();

    try table.increment("k");
    try table.increment("k");
    try std.testing.expectEqual(@as(u64, 2), table.get("k"));
}
