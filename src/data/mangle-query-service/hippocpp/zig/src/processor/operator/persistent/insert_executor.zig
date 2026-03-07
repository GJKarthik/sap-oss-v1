//! Executor for insert operations.

const std = @import("std");

pub const InsertExecutor = struct {
    allocator: std.mem.Allocator,
    inserted_rows: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) InsertExecutor {
        return .{ .allocator = allocator };
    }

    pub fn execute(self: *InsertExecutor, row_count: usize) void {
        self.inserted_rows += @intCast(row_count);
    }
};

test "insert executor counts rows" {
    const allocator = std.testing.allocator;
    var exec = InsertExecutor.init(allocator);
    exec.execute(3);
    try std.testing.expectEqual(@as(u64, 3), exec.inserted_rows);
}
