//! Table Schema for ainuc-gen-foundry.
//!
//! Defines table metadata (columns, types, PK/FK), CSV loading,
//! and validation result types. Equivalent to the Python
//! definition/base/table.py + database.py abstractions.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ============================================================================
// Column Types
// ============================================================================

pub const ColumnType = enum {
    text,
    integer,
    float,
    boolean,

    pub fn toString(self: ColumnType) []const u8 {
        return switch (self) {
            .text => "TEXT",
            .integer => "INTEGER",
            .float => "DOUBLE",
            .boolean => "BOOLEAN",
        };
    }

    pub fn fromString(s: []const u8) ColumnType {
        if (mem.eql(u8, s, "INTEGER") or mem.eql(u8, s, "INT") or mem.eql(u8, s, "BIGINT")) return .integer;
        if (mem.eql(u8, s, "DOUBLE") or mem.eql(u8, s, "FLOAT") or mem.eql(u8, s, "DECIMAL")) return .float;
        if (mem.eql(u8, s, "BOOLEAN") or mem.eql(u8, s, "BOOL")) return .boolean;
        return .text;
    }
};

// ============================================================================
// Column Definition
// ============================================================================

pub const Column = struct {
    name: []const u8,
    col_type: ColumnType,
    nullable: bool = true,
    is_primary_key: bool = false,
};

// ============================================================================
// Foreign Key
// ============================================================================

pub const ForeignKey = struct {
    column: []const u8,
    ref_table: []const u8,
    ref_column: []const u8,
};

// ============================================================================
// Table Schema (supports both static slices and dynamic ArrayList)
// ============================================================================

pub const TableSchema = struct {
    name: []const u8,
    // Dynamic column list (used when building schema at runtime)
    columns: std.ArrayList(Column),
    primary_key: []const []const u8 = &.{},
    foreign_keys: std.ArrayList(ForeignKey),
    // Static column slice (used for compile-time schemas)
    static_columns: ?[]const Column = null,
    static_foreign_keys: ?[]const ForeignKey = null,

    pub fn init(allocator: Allocator, name: []const u8) TableSchema {
        _ = allocator;
        return .{
            .name = name,
            .columns = .{},
            .foreign_keys = .{},
        };
    }

    pub fn initStatic(name: []const u8, cols: []const Column, pks: []const []const u8, fks: []const ForeignKey) TableSchema {
        return .{
            .name = name,
            .columns = .{},
            .primary_key = pks,
            .foreign_keys = .{},
            .static_columns = cols,
            .static_foreign_keys = fks,
        };
    }

    pub fn deinit(self: *TableSchema, allocator: Allocator) void {
        self.columns.deinit(allocator);
        self.foreign_keys.deinit(allocator);
    }

    pub fn addColumn(self: *TableSchema, allocator: Allocator, col: Column) !void {
        try self.columns.append(allocator, col);
    }

    pub fn addForeignKey(self: *TableSchema, allocator: Allocator, fk: ForeignKey) !void {
        try self.foreign_keys.append(allocator, fk);
    }

    /// Get the effective column list (dynamic or static).
    pub fn getColumns(self: *const TableSchema) []const Column {
        if (self.static_columns) |sc| return sc;
        return self.columns.items;
    }

    /// Get the effective FK list.
    pub fn getForeignKeys(self: *const TableSchema) []const ForeignKey {
        if (self.static_foreign_keys) |sf| return sf;
        return self.foreign_keys.items;
    }

    /// Serialize to JSON for LLM context (equivalent to Table.to_llm_schema)
    pub fn toJson(self: *const TableSchema, allocator: Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .{};
        var w = buf.writer(allocator);

        const cols = self.getColumns();
        const fks = self.getForeignKeys();

        try w.print("{{\"name\":\"{s}\",\"columns\":[", .{self.name});

        for (cols, 0..) |col, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"name\":\"{s}\",\"type\":\"{s}\",\"nullable\":{s}", .{
                col.name,
                col.col_type.toString(),
                if (col.nullable) "true" else "false",
            });
            if (col.is_primary_key) {
                try w.writeAll(",\"primary_key\":true");
            }
            try w.writeAll("}");
        }

        try w.writeAll("],\"primary_keys\":[");
        for (self.primary_key, 0..) |pk, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{pk});
        }

        try w.writeAll("],\"foreign_keys\":[");
        for (fks, 0..) |fk, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"column\":\"{s}\",\"references\":\"{s}.{s}\"}}", .{
                fk.column,
                fk.ref_table,
                fk.ref_column,
            });
        }

        try w.writeAll("]}");
        return buf.toOwnedSlice(allocator);
    }
};

// ============================================================================
// Row — generic row with dynamic cells
// ============================================================================

pub const CellValue = union(enum) {
    text: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    null_val: void,
};

pub const Row = struct {
    cells: std.ArrayList(CellValue) = .{},

    pub fn init(_: Allocator) Row {
        return .{ .cells = .{} };
    }

    pub fn deinit(self: *Row, allocator: Allocator) void {
        self.cells.deinit(allocator);
    }

    pub fn addCell(self: *Row, allocator: Allocator, val: CellValue) !void {
        try self.cells.append(allocator, val);
    }
};

// ============================================================================
// Table Data — schema + dynamic rows
// ============================================================================

pub const TableData = struct {
    schema_ref: *const TableSchema,
    rows: std.ArrayList(Row),

    pub fn init(_: Allocator, schema_ref: *const TableSchema) TableData {
        return .{
            .schema_ref = schema_ref,
            .rows = .{},
        };
    }

    pub fn deinit(self: *TableData, allocator: Allocator) void {
        for (self.rows.items) |*row| {
            row.deinit(allocator);
        }
        self.rows.deinit(allocator);
    }

    pub fn addRow(self: *TableData, allocator: Allocator, row: Row) !void {
        try self.rows.append(allocator, row);
    }

    pub fn rowCount(self: *const TableData) usize {
        return self.rows.items.len;
    }

    /// Serialize up to `max_rows` rows as JSON for LLM context
    pub fn toJsonSample(self: *const TableData, allocator: Allocator, max_rows: usize) ![]const u8 {
        var buf: std.ArrayList(u8) = .{};
        var w = buf.writer(allocator);

        const cols = self.schema_ref.getColumns();
        const limit = @min(self.rows.items.len, max_rows);

        try w.print("{{\"table\":\"{s}\",\"row_count\":{d},\"sample_rows\":[", .{
            self.schema_ref.name,
            self.rows.items.len,
        });

        for (self.rows.items[0..limit], 0..) |row, ri| {
            if (ri > 0) try w.writeAll(",");
            try w.writeAll("{");
            for (row.cells.items, 0..) |val, ci| {
                if (ci > 0) try w.writeAll(",");
                if (ci < cols.len) {
                    try w.print("\"{s}\":", .{cols[ci].name});
                }
                switch (val) {
                    .text => |t| try w.print("\"{s}\"", .{t}),
                    .integer => |n| try w.print("{d}", .{n}),
                    .float => |f| try w.print("{d:.6}", .{f}),
                    .boolean => |b| try w.writeAll(if (b) "true" else "false"),
                    .null_val => try w.writeAll("null"),
                }
            }
            try w.writeAll("}");
        }

        try w.writeAll("]}");
        return buf.toOwnedSlice(allocator);
    }
};

// ============================================================================
// Validation Result
// ============================================================================

pub const ValidationIssue = struct {
    table_name: []const u8,
    column: []const u8,
    check_name: []const u8,
    row_index: usize,
    failure_case: []const u8,
};

pub const ValidationResult = struct {
    check_name: []const u8,
    description: []const u8,
    issues: []ValidationIssue,
    passed: bool,
};

// ============================================================================
// Database (collection of tables)
// ============================================================================

pub const Database = struct {
    allocator: Allocator,
    id: []const u8,
    schemas: std.StringHashMap(TableSchema),
    data: std.StringHashMap(TableData),
    checks: std.StringHashMap(ValidationResult),

    pub fn init(allocator: Allocator, id: []const u8) Database {
        return .{
            .allocator = allocator,
            .id = id,
            .schemas = std.StringHashMap(TableSchema).init(allocator),
            .data = std.StringHashMap(TableData).init(allocator),
            .checks = std.StringHashMap(ValidationResult).init(allocator),
        };
    }

    pub fn deinit(self: *Database) void {
        var s_iter = self.schemas.iterator();
        while (s_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.schemas.deinit();

        var d_iter = self.data.iterator();
        while (d_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.data.deinit();
        self.checks.deinit();
    }

    pub fn tableCount(self: *const Database) usize {
        return self.schemas.count();
    }

    /// Register a table schema (without data).
    pub fn addSchema(self: *Database, schema: TableSchema) !void {
        try self.schemas.put(schema.name, schema);
    }

    /// Register table data for an already-registered schema.
    pub fn addTableData(self: *Database, table_name: []const u8, td: TableData) !void {
        try self.data.put(table_name, td);
    }

    /// Get a table schema by name.
    pub fn getTableSchema(self: *const Database, name: []const u8) ?*const TableSchema {
        return if (self.schemas.getPtr(name)) |ptr| ptr else null;
    }

    /// Get table data by name.
    pub fn getTableData(self: *const Database, name: []const u8) ?*const TableData {
        return if (self.data.getPtr(name)) |ptr| ptr else null;
    }

    /// Get all table names.
    pub fn getTableNames(self: *const Database, allocator: Allocator) ![]const []const u8 {
        var names: std.ArrayList([]const u8) = .{};
        var iter = self.schemas.iterator();
        while (iter.next()) |entry| {
            try names.append(allocator, entry.key_ptr.*);
        }
        return names.toOwnedSlice(allocator);
    }

    /// Serialize full database schema for LLM context
    pub fn schemaToJson(self: *const Database, allocator: Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .{};
        var w = buf.writer(allocator);

        try w.print("{{\"database\":\"{s}\",\"tables\":[", .{self.id});

        var first = true;
        var iter = self.schemas.iterator();
        while (iter.next()) |entry| {
            if (!first) try w.writeAll(",");
            const table_json = try entry.value_ptr.toJson(allocator);
            defer allocator.free(table_json);
            try w.writeAll(table_json);
            first = false;
        }

        try w.writeAll("]}");
        return buf.toOwnedSlice(allocator);
    }

    /// Serialize table data as JSON (up to 10 sample rows).
    pub fn tableDataToJson(self: *const Database, allocator: Allocator, table_name: []const u8) ![]const u8 {
        const td = self.getTableData(table_name) orelse return error.TableNotFound;
        return td.toJsonSample(allocator, 10);
    }
};

// ============================================================================
// CSV Loader
// ============================================================================

/// Parse a CSV file into rows of text CellValues.
/// Caller owns the returned slice.
pub fn loadCsv(allocator: Allocator, path: []const u8) !struct { headers: [][]const u8, rows: [][]const []const u8 } {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 64 * 1024 * 1024); // 64 MB max
    defer allocator.free(content);

    var headers: std.ArrayList([]const u8) = .{};
    var all_rows: std.ArrayList([]const []const u8) = .{};

    var line_iter = mem.splitScalar(u8, content, '\n');
    var first_line = true;

    while (line_iter.next()) |line| {
        const trimmed = mem.trim(u8, line, &[_]u8{ '\r', ' ' });
        if (trimmed.len == 0) continue;

        var fields: std.ArrayList([]const u8) = .{};
        var field_iter = mem.splitScalar(u8, trimmed, ',');

        while (field_iter.next()) |field| {
            const f = mem.trim(u8, field, &[_]u8{ '"', ' ' });
            try fields.append(allocator, try allocator.dupe(u8, f));
        }

        if (first_line) {
            headers = fields;
            first_line = false;
        } else {
            try all_rows.append(allocator, try fields.toOwnedSlice(allocator));
        }
    }

    return .{
        .headers = try headers.toOwnedSlice(allocator),
        .rows = try all_rows.toOwnedSlice(allocator),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "column type from string" {
    try std.testing.expectEqual(ColumnType.integer, ColumnType.fromString("INTEGER"));
    try std.testing.expectEqual(ColumnType.float, ColumnType.fromString("DOUBLE"));
    try std.testing.expectEqual(ColumnType.text, ColumnType.fromString("VARCHAR"));
}

test "table schema to json" {
    const allocator = std.testing.allocator;

    const cols = [_]Column{
        .{ .name = "id", .col_type = .integer, .nullable = false, .is_primary_key = true },
        .{ .name = "name", .col_type = .text, .nullable = true, .is_primary_key = false },
    };
    const pks = [_][]const u8{"id"};
    const fks = [_]ForeignKey{};

    const schema = TableSchema.initStatic("users", &cols, &pks, &fks);

    const json = try schema.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(mem.indexOf(u8, json, "\"users\"") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"primary_key\":true") != null);
}

test "database schema to json" {
    const allocator = std.testing.allocator;

    var db = Database.init(allocator, "test_db");
    defer db.deinit();

    var ts = TableSchema.init(allocator, "orders");
    try ts.addColumn(allocator, .{ .name = "id", .col_type = .integer, .nullable = false, .is_primary_key = true });
    try ts.addColumn(allocator, .{ .name = "amount", .col_type = .float });
    try db.addSchema(ts);

    const json = try db.schemaToJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(mem.indexOf(u8, json, "\"test_db\"") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"orders\"") != null);
    try std.testing.expectEqual(@as(usize, 1), db.tableCount());
}
