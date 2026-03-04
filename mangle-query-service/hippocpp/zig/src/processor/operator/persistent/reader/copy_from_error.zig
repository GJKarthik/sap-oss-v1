//! COPY FROM error model.

const std = @import("std");

pub const CopyFromError = struct {
    row_index: u64,
    column_name: ?[]const u8 = null,
    message: []const u8,

    pub fn format(self: CopyFromError, allocator: std.mem.Allocator) ![]u8 {
        if (self.column_name) |col| {
            return std.fmt.allocPrint(allocator, "row {d}, column {s}: {s}", .{ self.row_index, col, self.message });
        }
        return std.fmt.allocPrint(allocator, "row {d}: {s}", .{ self.row_index, self.message });
    }
};

test "copy from error format" {
    const allocator = std.testing.allocator;
    const err = CopyFromError{ .row_index = 3, .column_name = "age", .message = "invalid INT64" };
    const msg = try err.format(allocator);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "column age") != null);
}
