//! Node-specific batch insert error handling.

const base = @import("batch_insert_error_handler.zig");

pub const NodeBatchInsertErrorHandler = struct {
    inner: base.BatchInsertErrorHandler,

    pub fn init(allocator: @import("std").mem.Allocator) NodeBatchInsertErrorHandler {
        return .{ .inner = base.BatchInsertErrorHandler.init(allocator) };
    }

    pub fn deinit(self: *NodeBatchInsertErrorHandler) void {
        self.inner.deinit();
    }

    pub fn recordNodeError(self: *NodeBatchInsertErrorHandler, row_index: u64, message: []const u8) !void {
        try self.inner.record(row_index, message);
    }
};
