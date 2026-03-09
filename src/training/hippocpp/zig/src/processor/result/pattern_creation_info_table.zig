//! Pattern creation info tracking for CREATE/MERGE operations.

const std = @import("std");

pub const PatternCreationInfo = struct {
    pattern_name: []const u8,
    created_nodes: u64,
    created_rels: u64,
};

pub const PatternCreationInfoTable = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayList(PatternCreationInfo),

    pub fn init(allocator: std.mem.Allocator) PatternCreationInfoTable {
        return .{
            .allocator = allocator,
            .rows = .{},
        };
    }

    pub fn deinit(self: *PatternCreationInfoTable) void {
        self.rows.deinit(self.allocator);
    }

    pub fn append(self: *PatternCreationInfoTable, row: PatternCreationInfo) !void {
        try self.rows.append(self.allocator, row);
    }

    pub fn totalCreatedNodes(self: *const PatternCreationInfoTable) u64 {
        var total: u64 = 0;
        for (self.rows.items) |row| total += row.created_nodes;
        return total;
    }
};

test "pattern creation totals" {
    const allocator = std.testing.allocator;
    var table = PatternCreationInfoTable.init(allocator);
    defer table.deinit(std.testing.allocator);

    try table.append(std.testing.allocator, .{ .pattern_name = "p1", .created_nodes = 2, .created_rels = 1 });
    try table.append(std.testing.allocator, .{ .pattern_name = "p2", .created_nodes = 3, .created_rels = 0 });
    try std.testing.expectEqual(@as(u64, 5), table.totalCreatedNodes());
}
