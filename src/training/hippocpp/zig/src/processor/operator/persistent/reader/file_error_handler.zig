//! File-level error aggregation for readers.

const std = @import("std");
const copy_err = @import("copy_from_error.zig");

pub const FileErrorHandler = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(copy_err.CopyFromError),

    pub fn init(allocator: std.mem.Allocator) FileErrorHandler {
        return .{ .allocator = allocator, .errors = .{} };
    }

    pub fn deinit(self: *FileErrorHandler) void {
        self.errors.deinit(self.allocator);
    }

    pub fn record(self: *FileErrorHandler, err: copy_err.CopyFromError) !void {
        try self.errors.append(self.allocator, err);
    }

    pub fn count(self: *const FileErrorHandler) usize {
        return self.errors.items.len;
    }
};
