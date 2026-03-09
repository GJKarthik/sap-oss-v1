//! Relationship batch insert helper for COPY operations.

const std = @import("std");
const types = @import("persistent_types.zig");

pub const RelationshipRecord = struct {
    src: []const u8,
    dst: []const u8,
};

pub const CopyRelBatchInsert = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayList(RelationshipRecord),

    pub fn init(allocator: std.mem.Allocator) CopyRelBatchInsert {
        return .{ .allocator = allocator, .rows = .{} };
    }

    pub fn deinit(self: *CopyRelBatchInsert) void {
        self.rows.deinit(self.allocator);
    }

    pub fn append(self: *CopyRelBatchInsert, src: []const u8, dst: []const u8) !void {
        try self.rows.append(self.allocator, .{ .src = types.trimLine(src);
    }
};

test "copy rel batch insert append" {
    const allocator = std.testing.allocator;
    var rel = CopyRelBatchInsert.init(allocator);
    defer rel.deinit(std.testing.allocator);
    try rel.append(std.testing.allocator, " a ", " b ");
    try std.testing.expectEqual(@as(usize, 1), rel.rows.items.len);
}
