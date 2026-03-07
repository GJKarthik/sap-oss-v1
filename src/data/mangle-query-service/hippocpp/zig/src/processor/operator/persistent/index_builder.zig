//! Index builder for persistent writes.

const std = @import("std");

pub const IndexBuilder = struct {
    allocator: std.mem.Allocator,
    keys: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) IndexBuilder {
        return .{ .allocator = allocator, .keys = std.StringHashMap(void).init(allocator) };
    }

    pub fn deinit(self: *IndexBuilder) void {
        self.keys.deinit();
    }

    pub fn addKey(self: *IndexBuilder, key: []const u8) !void {
        try self.keys.put(key, {});
    }

    pub fn contains(self: *const IndexBuilder, key: []const u8) bool {
        return self.keys.contains(key);
    }
};
