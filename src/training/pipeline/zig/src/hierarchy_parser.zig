const std = @import("std");
const csv_parser = @import("csv_parser.zig");
const schema_registry = @import("schema_registry.zig");

pub const DimensionType = enum {
    ACCOUNT,
    PRODUCT,
    LOCATION,
    COST_CLUSTER,
    SEGMENT,
};

pub fn parseHierarchy(
    allocator: std.mem.Allocator,
    csv_data: []const u8,
    dim_type: DimensionType,
) !schema_registry.Table {
    var parser = csv_parser.CsvParser.init(allocator, csv_data);

    // First row is header
    var header = try parser.nextRow() orelse return error.EmptyFile;
    defer header.deinit();

    // Count hierarchy levels from header (columns named "X (L0)", "X (L1)", etc.)
    var level_count: u8 = 0;
    var level_indices: [8]usize = .{0} ** 8;
    for (header.fields, 0..) |field, i| {
        if (std.mem.indexOf(u8, field, "(L") != null) {
            if (level_count < 8) {
                level_indices[level_count] = i;
                level_count += 1;
            }
        }
    }

    // Collect unique values per level
    var level_values: [8]std.StringHashMap(void) = undefined;
    for (0..level_count) |i| {
        level_values[i] = std.StringHashMap(void).init(allocator);
    }
    defer for (0..level_count) |i| {
        var it = level_values[i].keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        level_values[i].deinit();
    };

    var row_count: usize = 0;
    while (try parser.nextRow()) |row_val| {
        var row = row_val;
        defer row.deinit();
        row_count += 1;

        for (0..level_count) |lvl| {
            const idx = level_indices[lvl];
            if (idx < row.fields.len and row.fields[idx].len > 0) {
                if (level_values[lvl].get(row.fields[idx]) == null) {
                    const val = try allocator.dupe(u8, row.fields[idx]);
                    try level_values[lvl].put(val, {});
                }
            }
        }
    }

    // Build hierarchy levels
    var levels: std.ArrayList(schema_registry.HierarchyLevel) = .empty;
    for (0..level_count) |lvl| {
        var values: std.ArrayList([]const u8) = .empty;
        var it = level_values[lvl].keyIterator();
        while (it.next()) |key| {
            try values.append(allocator, try allocator.dupe(u8, key.*));
        }
        try levels.append(allocator, .{
            .level = @intCast(lvl),
            .name = try allocator.dupe(u8, header.fields[level_indices[lvl]]),
            .values = try values.toOwnedSlice(allocator),
        });
    }

    const table_name = switch (dim_type) {
        .ACCOUNT => "NFRP_Account",
        .PRODUCT => "NFRP_Product",
        .LOCATION => "NFRP_Location",
        .COST_CLUSTER => "NFRP_Cost",
        .SEGMENT => "NFRP_Segment",
    };

    return schema_registry.Table{
        .name = try allocator.dupe(u8, table_name),
        .schema_name = try allocator.dupe(u8, "DIM"),
        .domain = .PERFORMANCE,
        .columns = &.{},
        .hierarchy_levels = try levels.toOwnedSlice(allocator),
        .row_count = row_count,
        .description = try allocator.dupe(u8, "NFRP dimension table"),
    };
}

test "parse account hierarchy" {
    const allocator = std.testing.allocator;
    const csv_data =
        \\ACCOUNT,ACCOUNT (L0),ACCOUNT (L1),ACCOUNT (L2)
        \\Income,Income,NII,NII
        \\Income,Income,NFI,Fee Income
        \\Cost,Total Cost,Staff Costs,Staff Costs
    ;

    const table = try parseHierarchy(allocator, csv_data, .ACCOUNT);
    defer {
        allocator.free(table.name);
        allocator.free(table.schema_name);
        allocator.free(table.description);
        for (table.hierarchy_levels) |hl| {
            allocator.free(hl.name);
            for (hl.values) |v| allocator.free(v);
            allocator.free(hl.values);
        }
        allocator.free(table.hierarchy_levels);
    }
    try std.testing.expectEqualStrings("NFRP_Account", table.name);
    try std.testing.expectEqual(@as(usize, 3), table.hierarchy_levels.len);
    try std.testing.expectEqual(@as(usize, 3), table.row_count);
    try std.testing.expectEqual(@as(u8, 0), table.hierarchy_levels[0].level);
    try std.testing.expectEqual(@as(usize, 2), table.hierarchy_levels[0].values.len);
}

