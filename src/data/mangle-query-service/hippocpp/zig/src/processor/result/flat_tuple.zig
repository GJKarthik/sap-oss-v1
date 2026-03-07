//! Flat tuple representation for projected output rows.

const std = @import("std");
const table_mod = @import("factorized_table.zig");

pub const FlatTuple = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(table_mod.CellValue),

    pub fn init(allocator: std.mem.Allocator) FlatTuple {
        return .{
            .allocator = allocator,
            .values = std.ArrayList(table_mod.CellValue).init(allocator),
        };
    }

    pub fn deinit(self: *FlatTuple) void {
        self.values.deinit();
    }

    pub fn append(self: *FlatTuple, value: table_mod.CellValue) !void {
        try self.values.append(value);
    }

    pub fn get(self: *const FlatTuple, idx: usize) ?table_mod.CellValue {
        if (idx >= self.values.items.len) return null;
        return self.values.items[idx];
    }
};

test "flat tuple append and get" {
    const allocator = std.testing.allocator;
    var tuple = FlatTuple.init(allocator);
    defer tuple.deinit();

    try tuple.append(.{ .int64_val = 7 });
    try std.testing.expect(tuple.get(0) != null);
}
