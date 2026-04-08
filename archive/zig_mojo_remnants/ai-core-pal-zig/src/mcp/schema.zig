const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ============================================================================
// Column — basic column metadata
// ============================================================================

pub const ColumnType = enum {
    text,
    integer,
    float,
    boolean,
    null_val,

    pub fn toString(self: ColumnType) []const u8 {
        return switch (self) {
            .text => "string",
            .integer => "integer",
            .float => "float",
            .boolean => "boolean",
            .null_val => "null",
        };
    }
};

pub const Column = struct {
    name: []const u8,
    col_type: ColumnType,
    nullable: bool = true,
    is_primary_key: bool = false,
};

pub const ForeignKey = struct {
    column: []const u8,
    ref_table: []const u8,
    ref_column: []const u8,
};

// ============================================================================
// Table Schema — dynamic or static table definition
// ============================================================================

pub const TableSchema = struct {
    name: []const u8,
    columns: std.ArrayList(Column),
    foreign_keys: std.ArrayList(ForeignKey),
    primary_key: []const []const u8,
    static_columns: ?[]const Column = null,
    static_foreign_keys: ?[]const ForeignKey = null,

    pub fn init(allocator: Allocator, name: []const u8) TableSchema {
        return .{
            .name = name,
            .columns = std.ArrayList(Column).init(allocator),
            .foreign_keys = std.ArrayList(ForeignKey).init(allocator),
            .primary_key = &.{},
        };
    }

    pub fn deinit(self: *TableSchema) void {
        self.columns.deinit();
        self.foreign_keys.deinit();
    }

    pub fn addColumn(self: *TableSchema, col: Column) !void {
        try self.columns.append(col);
    }

    pub fn addForeignKey(self: *TableSchema, fk: ForeignKey) !void {
        try self.foreign_keys.append(fk);
    }

    pub fn getColumns(self: *const TableSchema) []const Column {
        if (self.static_columns) |sc| return sc;
        return self.columns.items;
    }

    pub fn getForeignKeys(self: *const TableSchema) []const ForeignKey {
        if (self.static_foreign_keys) |sf| return sf;
        return self.foreign_keys.items;
    }

    pub fn toJson(self: *const TableSchema, allocator: Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        var w = buf.writer();

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
            if (col.is_primary_key) try w.writeAll(",\"primary_key\":true");
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
        return try buf.toOwnedSlice();
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
    cells: std.ArrayList(CellValue),

    pub fn init(allocator: Allocator) Row {
        return .{ .cells = std.ArrayList(CellValue).init(allocator) };
    }

    pub fn deinit(self: *Row) void {
        self.cells.deinit();
    }

    pub fn addCell(self: *Row, val: CellValue) !void {
        try self.cells.append(val);
    }
};

// ============================================================================
// Table Data — schema + dynamic rows
// ============================================================================

pub const TableData = struct {
    schema_ref: *const TableSchema,
    rows: std.ArrayList(Row),

    pub fn init(allocator: Allocator, schema_ref: *const TableSchema) TableData {
        return .{
            .schema_ref = schema_ref,
            .rows = std.ArrayList(Row).init(allocator),
        };
    }

    pub fn deinit(self: *TableData) void {
        for (self.rows.items) |*row| {
            row.deinit();
        }
        self.rows.deinit();
    }

    pub fn addRow(self: *TableData, row: Row) !void {
        try self.rows.append(row);
    }

    pub fn rowCount(self: *const TableData) usize {
        return self.rows.items.len;
    }
};

// ============================================================================
// Database — collection of table schemas
// ============================================================================

pub const Database = struct {
    allocator: Allocator,
    schemas: std.ArrayList(TableSchema),

    pub fn init(allocator: Allocator) Database {
        return .{
            .allocator = allocator,
            .schemas = std.ArrayList(TableSchema).init(allocator),
        };
    }

    pub fn deinit(self: *Database) void {
        for (self.schemas.items) |*schema| {
            schema.deinit();
        }
        self.schemas.deinit();
    }

    pub fn addSchema(self: *Database, schema: TableSchema) !void {
        try self.schemas.append(schema);
    }

    pub fn tableCount(self: *const Database) usize {
        return self.schemas.items.len;
    }

    pub fn getTableSchema(self: *const Database, name: []const u8) ?*const TableSchema {
        for (self.schemas.items) |*schema| {
            if (mem.eql(u8, schema.name, name)) return schema;
        }
        return null;
    }

    pub fn toJson(self: *const Database, allocator: Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        var w = buf.writer();
        try w.writeAll("[");
        for (self.schemas.items, 0..) |*schema, i| {
            if (i > 0) try w.writeAll(",");
            const s_json = try schema.toJson(allocator);
            defer allocator.free(s_json);
            try w.writeAll(s_json);
        }
        try w.writeAll("]");
        return try buf.toOwnedSlice();
    }
};
