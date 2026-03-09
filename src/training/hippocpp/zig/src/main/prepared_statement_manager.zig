//! Prepared statement manager similar to Kuzu main layer.

const std = @import("std");
const prepared_mod = @import("prepared_statement.zig");

pub const PreparedStatementManager = struct {
    allocator: std.mem.Allocator,
    cache: prepared_mod.PreparedStatementCache,

    pub fn init(allocator: std.mem.Allocator) PreparedStatementManager {
        return .{
            .allocator = allocator,
            .cache = prepared_mod.PreparedStatementCache.init(allocator),
        };
    }

    pub fn deinit(self: *PreparedStatementManager) void {
        self.cache.deinit(self.allocator);
    }

    pub fn prepare(self: *PreparedStatementManager, query: []const u8) !*prepared_mod.PreparedStatement {
        return self.cache.getOrCreate(query);
    }

    pub fn remove(self: *PreparedStatementManager, query: []const u8) void {
        self.cache.remove(query);
    }

    pub fn clear(self: *PreparedStatementManager) void {
        self.cache.clear();
    }

    pub fn size(self: *const PreparedStatementManager) usize {
        return self.cache.size();
    }
};

test "prepared statement manager lifecycle" {
    const allocator = std.testing.allocator;
    var manager = PreparedStatementManager.init(allocator);
    defer manager.deinit(std.testing.allocator);

    const stmt = try manager.prepare("SELECT 1");
    try std.testing.expect(stmt.isPrepared());
    try std.testing.expectEqual(@as(usize, 1), manager.size());
}
