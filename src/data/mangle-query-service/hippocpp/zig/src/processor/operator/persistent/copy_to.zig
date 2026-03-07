//! COPY TO execution support.

const std = @import("std");
const types = @import("persistent_types.zig");

pub const CopyToExecutor = struct {
    allocator: std.mem.Allocator,
    stats: types.WriteStats = .{},

    pub fn init(allocator: std.mem.Allocator) CopyToExecutor {
        return .{ .allocator = allocator };
    }

    pub fn writeCsvLine(self: *CopyToExecutor, writer: anytype, values: []const []const u8) !void {
        for (values, 0..) |v, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("{s}", .{v});
        }
        try writer.writeByte('\n');
        self.stats.bytes_written += 1;
    }
};
