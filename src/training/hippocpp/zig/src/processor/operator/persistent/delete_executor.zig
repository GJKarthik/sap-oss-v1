//! Executor for delete operations.

const std = @import("std");
const del = @import("delete.zig");

pub const DeleteExecutor = struct {
    allocator: std.mem.Allocator,
    deleted_rows: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) DeleteExecutor {
        return .{ .allocator = allocator };
    }

    pub fn execute(self: *DeleteExecutor, batch: *const del.DeleteBatch) void {
        self.deleted_rows += @intCast(batch.ops.items.len);
    }
};

test "delete executor counts deletes" {
    const allocator = std.testing.allocator;
    var batch = del.DeleteBatch.init(allocator);
    defer batch.deinit(std.testing.allocator);
    try batch.add("Person", "1");
    try batch.add("Person", "2");

    var exec = DeleteExecutor.init(allocator);
    exec.execute(&batch);
    try std.testing.expectEqual(@as(u64, 2), exec.deleted_rows);
}
