//! Error tracking for batched insert operations.

const std = @import("std");

pub const BatchInsertError = struct {
    row_index: u64,
    message: []const u8,
};

pub const BatchInsertErrorHandler = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(BatchInsertError),

    pub fn init(allocator: std.mem.Allocator) BatchInsertErrorHandler {
        return .{ .allocator = allocator, .errors = std.ArrayList(BatchInsertError).init(allocator) };
    }

    pub fn deinit(self: *BatchInsertErrorHandler) void {
        self.errors.deinit();
    }

    pub fn record(self: *BatchInsertErrorHandler, row_index: u64, message: []const u8) !void {
        try self.errors.append(.{ .row_index = row_index, .message = message });
    }

    pub fn hasErrors(self: *const BatchInsertErrorHandler) bool {
        return self.errors.items.len > 0;
    }

    pub fn errorCount(self: *const BatchInsertErrorHandler) usize {
        return self.errors.items.len;
    }
};

test "batch insert error handler" {
    const allocator = std.testing.allocator;
    var handler = BatchInsertErrorHandler.init(allocator);
    defer handler.deinit();

    try handler.record(1, "duplicate key");
    try std.testing.expect(handler.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), handler.errorCount());
}
