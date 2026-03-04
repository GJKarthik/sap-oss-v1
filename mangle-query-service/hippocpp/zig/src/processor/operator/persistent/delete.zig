//! Persistent delete operation model.

const std = @import("std");
const types = @import("persistent_types.zig");

pub const DeleteOperation = struct {
    mutation: types.RowMutation,
};

pub const DeleteBatch = struct {
    allocator: std.mem.Allocator,
    ops: std.ArrayList(DeleteOperation),

    pub fn init(allocator: std.mem.Allocator) DeleteBatch {
        return .{ .allocator = allocator, .ops = std.ArrayList(DeleteOperation).init(allocator) };
    }

    pub fn deinit(self: *DeleteBatch) void {
        self.ops.deinit();
    }

    pub fn add(self: *DeleteBatch, table: []const u8, key: []const u8) !void {
        try self.ops.append(.{ .mutation = .{ .table_name = table, .primary_key = key } });
    }
};
