const std = @import("std");
const schema_registry = @import("schema_registry.zig");

pub fn emitSchemaJson(
    registry: *const schema_registry.SchemaRegistry,
    writer: anytype,
) !void {
    try writer.writeAll("{\"tables\":[");
    for (registry.tables.items, 0..) |table, i| {
        if (i > 0) try writer.writeAll(",");
        try emitTable(table, writer);
    }
    try writer.writeAll("],\"join_paths\":[");
    for (registry.join_paths.items, 0..) |jp, i| {
        if (i > 0) try writer.writeAll(",");
        try emitJoinPath(jp, writer);
    }
    try writer.writeAll("]}");
}

fn emitTable(table: schema_registry.Table, writer: anytype) !void {
    try writer.writeAll("{\"name\":\"");
    try writeJsonEscaped(writer, table.name);
    try writer.writeAll("\",\"schema\":\"");
    try writeJsonEscaped(writer, table.schema_name);
    try writer.writeAll("\",\"domain\":\"");
    try writer.writeAll(@tagName(table.domain));
    try writer.writeAll("\",\"row_count\":");
    try writer.print("{d}", .{table.row_count});
    try writer.writeAll(",\"columns\":[");
    for (table.columns, 0..) |col, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("{\"name\":\"");
        try writeJsonEscaped(writer, col.name);
        try writer.writeAll("\",\"type\":\"");
        try writer.writeAll(@tagName(col.data_type));
        try writer.writeAll("\"}");
    }
    try writer.writeAll("],\"hierarchy_levels\":[");
    for (table.hierarchy_levels, 0..) |hl, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{{\"level\":{d},\"name\":\"", .{hl.level});
        try writeJsonEscaped(writer, hl.name);
        try writer.writeAll("\",\"value_count\":");
        try writer.print("{d}", .{hl.values.len});
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
}

fn emitJoinPath(jp: schema_registry.JoinPath, writer: anytype) !void {
    try writer.writeAll("{\"from_table\":\"");
    try writeJsonEscaped(writer, jp.from_table);
    try writer.writeAll("\",\"from_column\":\"");
    try writeJsonEscaped(writer, jp.from_column);
    try writer.writeAll("\",\"to_table\":\"");
    try writeJsonEscaped(writer, jp.to_table);
    try writer.writeAll("\",\"to_column\":\"");
    try writeJsonEscaped(writer, jp.to_column);
    try writer.writeAll("\"}");
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

test "emit empty registry" {
    const allocator = std.testing.allocator;
    var registry = schema_registry.SchemaRegistry.init(allocator);
    defer registry.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try emitSchemaJson(&registry, buf.writer(allocator));

    try std.testing.expectEqualStrings("{\"tables\":[],\"join_paths\":[]}", buf.items);
}

test "emit registry with table" {
    const allocator = std.testing.allocator;
    var registry = schema_registry.SchemaRegistry.init(allocator);
    defer registry.deinit();

    try registry.addTable(.{
        .name = "TEST_TABLE",
        .schema_name = "STG",
        .domain = .TREASURY,
        .columns = &.{},
        .hierarchy_levels = &.{},
        .row_count = 100,
        .description = "Test",
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try emitSchemaJson(&registry, buf.writer(allocator));

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "TEST_TABLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "TREASURY") != null);
}

