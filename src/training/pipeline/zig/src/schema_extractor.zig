const std = @import("std");
const csv_parser = @import("csv_parser.zig");
const schema_registry = @import("schema_registry.zig");

pub fn extractFromStagingCsv(
    allocator: std.mem.Allocator,
    csv_data: []const u8,
    registry: *schema_registry.SchemaRegistry,
) !void {
    var parser = csv_parser.CsvParser.init(allocator, csv_data);

    // Skip header rows (first 3 rows are metadata headers)
    var headers_skipped: u32 = 0;
    while (headers_skipped < 3) {
        if (try parser.nextRow()) |row_val| {
            var row = row_val;
            row.deinit();
        } else return;
        headers_skipped += 1;
    }

    // Track tables we've seen to avoid duplicates
    var seen_tables = std.StringHashMap(usize).init(allocator);
    defer {
        var it = seen_tables.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        seen_tables.deinit();
    }

    while (try parser.nextRow()) |row_val| {
        var row = row_val;
        defer row.deinit();

        if (row.fields.len < 10) continue;

        const schema_name = row.fields[5]; // BTP Staging Schema Name
        const table_name = row.fields[6]; // BTP Table Name
        const field_name = row.fields[7]; // BTP Field Name

        if (table_name.len == 0 or field_name.len == 0) continue;

        // Get or create table index
        if (seen_tables.get(table_name) == null) {
            const idx = registry.tables.items.len;
            try registry.addTable(.{
                .name = try allocator.dupe(u8, table_name),
                .schema_name = try allocator.dupe(u8, schema_name),
                .domain = domainFromUseCase(if (row.fields.len > 1) row.fields[1] else ""),
                .columns = &.{},
                .hierarchy_levels = &.{},
                .row_count = 0,
                .description = try allocator.dupe(u8, ""),
            });
            try seen_tables.put(try allocator.dupe(u8, table_name), idx);
        }
    }
}

fn domainFromUseCase(use_case: []const u8) schema_registry.Domain {
    if (std.mem.indexOf(u8, use_case, "TREASURY") != null or
        std.mem.indexOf(u8, use_case, "CAPITAL") != null)
    {
        return .TREASURY;
    }
    if (std.mem.indexOf(u8, use_case, "ESG") != null) {
        return .ESG;
    }
    return .PERFORMANCE;
}

test "extract tables from staging csv" {
    const allocator = std.testing.allocator;
    const csv_data =
        \\header1
        \\header2
        \\header3
        \\,TREASURY_CAPITAL,BCRS,"TABLE1",AS_OF_DATE,STG_BCRS,BSI_REM_FACT,AS_OF_DATE,Date field,TIMESTAMP,,,
        \\,TREASURY_CAPITAL,BCRS,"TABLE1",STATUS,STG_BCRS,BSI_REM_FACT,STATUS,Status field,NVARCHAR,,,
        \\,TREASURY_CAPITAL,BCRS,"TABLE2",COUNTRY,STG_BCRS,BSI_REM_DIM_COUNTRY,COUNTRY,Country name,NVARCHAR,,,
    ;

    var registry = schema_registry.SchemaRegistry.init(allocator);
    defer {
        // Free allocated table names and schema names
        for (registry.tables.items) |t| {
            allocator.free(t.name);
            allocator.free(t.schema_name);
            allocator.free(t.description);
        }
        registry.deinit();
    }

    try extractFromStagingCsv(allocator, csv_data, &registry);

    // Should have extracted 2 tables
    try std.testing.expectEqual(@as(usize, 2), registry.tables.items.len);
    try std.testing.expectEqualStrings("BSI_REM_FACT", registry.tables.items[0].name);
    try std.testing.expectEqualStrings("STG_BCRS", registry.tables.items[0].schema_name);
}

