//! Utilities for factorized table sizing and validation.

const std = @import("std");
const schema_mod = @import("factorized_table_schema.zig");
const table_mod = @import("factorized_table.zig");

pub fn estimateColumnSize(column_type: schema_mod.ColumnType) usize {
    return switch (column_type) {
        .bool => 1,
        .int64 => 8,
        .double => 8,
        .string => 24,
    };
}

pub fn estimateRowWidth(schema: *const schema_mod.FactorizedTableSchema) usize {
    var total: usize = 0;
    for (schema.columns.items) |col| {
        total += estimateColumnSize(col.column_type);
    }
    return total;
}

pub fn estimateTableBytes(table: *const table_mod.FactorizedTable) usize {
    return estimateRowWidth(&table.schema) * table.numRows();
}

test "estimate row width" {
    const allocator = std.testing.allocator;
    var schema = schema_mod.FactorizedTableSchema.init(allocator);
    defer schema.deinit();

    try schema.addColumn(.{ .name = "id", .column_type = .int64 });
    try schema.addColumn(.{ .name = "score", .column_type = .double });

    try std.testing.expectEqual(@as(usize, 16), estimateRowWidth(&schema));
}
