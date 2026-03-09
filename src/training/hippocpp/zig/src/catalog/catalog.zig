//! Catalog - Database schema and metadata management
//!
//! Purpose:
//! Manages database schemas, tables, indexes, and functions.
//! Provides transactional schema modification support.

const std = @import("std");

// ============================================================================
// Catalog Entry Types
// ============================================================================

pub const CatalogEntryType = enum {
    SCHEMA,
    TABLE,
    INDEX,
    FUNCTION,
    MACRO,
    SEQUENCE,
    TYPE,
};

// ============================================================================
// Table Schema
// ============================================================================

pub const TableType = enum {
    NODE_TABLE,
    REL_TABLE,
    RDF_TABLE,
    FOREIGN_TABLE,
};

pub const ColumnDefinition = struct {
    column_id: u32,
    name: []const u8,
    type_id: u8,
    nullable: bool = true,
    default_value: ?[]const u8 = null,
    
    pub fn init(column_id: u32, name: []const u8, type_id: u8) ColumnDefinition {
        return .{
            .column_id = column_id,
            .name = name,
            .type_id = type_id,
        };
    }
};

pub const TableSchema = struct {
    allocator: std.mem.Allocator,
    table_id: u64,
    name: []const u8,
    table_type: TableType,
    columns: std.ArrayList(ColumnDefinition),
    primary_key_columns: std.ArrayList(u32),
    properties: std.StringHashMap([]const u8),
    
    pub fn init(allocator: std.mem.Allocator, table_id: u64, name: []const u8, table_type: TableType) TableSchema {
        return .{
            .allocator = allocator,
            .table_id = table_id,
            .name = name,
            .table_type = table_type,
            .columns = .{},
            .primary_key_columns = .{},
            .properties = std.StringHashMap([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *TableSchema) void {
        self.columns.deinit(self.allocator);
        self.primary_key_columns.deinit(self.allocator);
        self.properties.deinit();
    }
    
    pub fn addColumn(self: *TableSchema, col: ColumnDefinition) !void {
        try self.columns.append(self.allocator, col);
    }
    
    pub fn getColumn(self: *const TableSchema, name: []const u8) ?*const ColumnDefinition {
        for (self.columns.items) |*col| {
            if (std.mem.eql(u8, col.name, name)) return col;
        }
        return null;
    }
    
    pub fn getColumnById(self: *const TableSchema, id: u32) ?*const ColumnDefinition {
        for (self.columns.items) |*col| {
            if (col.column_id == id) return col;
        }
        return null;
    }
    
    pub fn numColumns(self: *const TableSchema) usize {
        return self.columns.items.len;
    }
    
    pub fn setPrimaryKey(self: *TableSchema, column_ids: []const u32) !void {
        self.primary_key_columns.clearRetainingCapacity();
        try self.primary_key_columns.appendSlice(self.allocator, column_ids);
    }
};

// ============================================================================
// Index Definition
// ============================================================================

pub const IndexType = enum {
    HASH,
    BTREE,
    PRIMARY,
};

pub const IndexDefinition = struct {
    index_id: u64,
    name: []const u8,
    table_id: u64,
    index_type: IndexType,
    column_ids: []const u32,
    unique: bool = false,
    
    pub fn init(index_id: u64, name: []const u8, table_id: u64, index_type: IndexType, column_ids: []const u32) IndexDefinition {
        return .{
            .index_id = index_id,
            .name = name,
            .table_id = table_id,
            .index_type = index_type,
            .column_ids = column_ids,
        };
    }
};

// ============================================================================
// Function Definition
// ============================================================================

pub const FunctionType = enum {
    SCALAR,
    AGGREGATE,
    TABLE,
};

pub const FunctionDefinition = struct {
    function_id: u64,
    name: []const u8,
    function_type: FunctionType,
    param_types: []const u8,
    return_type: u8,
    variadic: bool = false,
    
    pub fn init(function_id: u64, name: []const u8, function_type: FunctionType) FunctionDefinition {
        return .{
            .function_id = function_id,
            .name = name,
            .function_type = function_type,
            .param_types = &[_]u8{},
            .return_type = 0,
        };
    }
};

// ============================================================================
// Catalog Entry
// ============================================================================

pub const CatalogEntry = struct {
    entry_id: u64,
    entry_type: CatalogEntryType,
    name: []const u8,
    created_tx: u64,
    deleted_tx: u64 = std.math.maxInt(u64),
    
    // Union of actual entry data
    data: union(enum) {
        table: *TableSchema,
        index: IndexDefinition,
        function: FunctionDefinition,
        none: void,
    },
    
    pub fn init(entry_id: u64, entry_type: CatalogEntryType, name: []const u8, tx_id: u64) CatalogEntry {
        return .{
            .entry_id = entry_id,
            .entry_type = entry_type,
            .name = name,
            .created_tx = tx_id,
            .data = .none,
        };
    }
    
    pub fn isVisible(self: *const CatalogEntry, tx_id: u64) bool {
        return self.created_tx <= tx_id and tx_id < self.deleted_tx;
    }
    
    pub fn markDeleted(self: *CatalogEntry, tx_id: u64) void {
        self.deleted_tx = tx_id;
    }
};

// ============================================================================
// Catalog
// ============================================================================

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    
    // Entry storage
    entries: std.ArrayList(CatalogEntry),
    tables: std.StringHashMap(*TableSchema),
    indexes: std.StringHashMap(IndexDefinition),
    functions: std.StringHashMap(FunctionDefinition),
    
    // ID generators
    next_table_id: u64 = 1,
    next_index_id: u64 = 1,
    next_function_id: u64 = 1,
    next_entry_id: u64 = 1,
    
    // Versioning
    version: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{
            .allocator = allocator,
            .entries = .{},
            .tables = std.StringHashMap(*TableSchema).init(allocator),
            .indexes = std.StringHashMap(IndexDefinition).init(allocator),
            .functions = std.StringHashMap(FunctionDefinition).init(allocator),
        };
    }
    
    pub fn deinit(self: *Catalog) void {
        var iter = self.tables.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        
        self.entries.deinit(self.allocator);
        self.tables.deinit();
        self.indexes.deinit();
        self.functions.deinit();
    }
    
    /// Create a new table
    pub fn createTable(self: *Catalog, name: []const u8, table_type: TableType, tx_id: u64) !*TableSchema {
        if (self.tables.contains(name)) {
            return error.TableAlreadyExists;
        }
        
        const table_id = self.next_table_id;
        self.next_table_id += 1;
        
        const schema = try self.allocator.create(TableSchema);
        schema.* = TableSchema.init(self.allocator, table_id, name, table_type);
        
        try self.tables.put(name, schema);
        
        // Create catalog entry
        var entry = CatalogEntry.init(self.next_entry_id, .TABLE, name, tx_id);
        self.next_entry_id += 1;
        entry.data = .{ .table = schema };
        try self.entries.append(self.allocator, entry);
        
        self.version += 1;
        return schema;
    }
    
    /// Drop a table
    pub fn dropTable(self: *Catalog, name: []const u8, tx_id: u64) !void {
        if (!self.tables.contains(name)) {
            return error.TableNotFound;
        }
        
        // Mark entry as deleted
        for (self.entries.items) |*entry| {
            if (entry.entry_type == .TABLE and std.mem.eql(u8, entry.name, name)) {
                if (entry.isVisible(tx_id)) {
                    entry.markDeleted(tx_id);
                    break;
                }
            }
        }
        
        if (self.tables.fetchRemove(name)) |kv| {
            self.allocator.destroy(kv.value);
        }
        self.version += 1;
    }
    
    /// Get table by name
    pub fn getTable(self: *const Catalog, name: []const u8) ?*TableSchema {
        return self.tables.get(name);
    }
    
    /// Get table by ID
    pub fn getTableById(self: *const Catalog, table_id: u64) ?*TableSchema {
        var iter = self.tables.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.table_id == table_id) {
                return entry.value_ptr.*;
            }
        }
        return null;
    }
    
    /// Create an index
    pub fn createIndex(self: *Catalog, name: []const u8, table_id: u64, index_type: IndexType, column_ids: []const u32, tx_id: u64) !IndexDefinition {
        if (self.indexes.contains(name)) {
            return error.IndexAlreadyExists;
        }
        
        const index_id = self.next_index_id;
        self.next_index_id += 1;
        
        const index = IndexDefinition.init(index_id, name, table_id, index_type, column_ids);
        try self.indexes.put(name, index);
        
        var entry = CatalogEntry.init(self.next_entry_id, .INDEX, name, tx_id);
        self.next_entry_id += 1;
        entry.data = .{ .index = index };
        try self.entries.append(self.allocator, entry);
        
        self.version += 1;
        return index;
    }
    
    /// Get index by name
    pub fn getIndex(self: *const Catalog, name: []const u8) ?IndexDefinition {
        return self.indexes.get(name);
    }
    
    /// Register a function
    pub fn registerFunction(self: *Catalog, name: []const u8, function_type: FunctionType, tx_id: u64) !FunctionDefinition {
        const function_id = self.next_function_id;
        self.next_function_id += 1;
        
        const func = FunctionDefinition.init(function_id, name, function_type);
        try self.functions.put(name, func);
        
        var entry = CatalogEntry.init(self.next_entry_id, .FUNCTION, name, tx_id);
        self.next_entry_id += 1;
        entry.data = .{ .function = func };
        try self.entries.append(self.allocator, entry);
        
        self.version += 1;
        return func;
    }
    
    /// Get function by name
    pub fn getFunction(self: *const Catalog, name: []const u8) ?FunctionDefinition {
        return self.functions.get(name);
    }
    
    /// Get _all _table names
    pub fn getTableNames(self: *const Catalog, _: std.mem.Allocator) ![][]const u8 {
        var names = .{};
        var iter = self.tables.iterator();
        while (iter.next()) |entry| {
            try names.append(self.allocator, entry.key_ptr.*);
        }
        return names.toOwnedSlice();
    }
    
    /// Get number of tables
    pub fn numTables(self: *const Catalog) usize {
        return self.tables.count();
    }
    
    /// Get catalog version
    pub fn getVersion(self: *const Catalog) u64 {
        return self.version;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "catalog create table" {
    const allocator = std.testing.allocator;
    
    var catalog = Catalog.init(allocator);
    defer catalog.deinit();
    
    const table = try catalog.createTable("users", .NODE_TABLE, 1);
    try table.addColumn(ColumnDefinition.init(0, "id", 6));  // INT64
    try table.addColumn(ColumnDefinition.init(1, "name", 14));  // STRING
    
    try std.testing.expectEqual(@as(u64, 1), table.table_id);
    try std.testing.expectEqual(@as(usize, 2), table.numColumns());
    try std.testing.expectEqual(@as(usize, 1), catalog.numTables());
}

test "catalog get table" {
    const allocator = std.testing.allocator;
    
    var catalog = Catalog.init(allocator);
    defer catalog.deinit();
    
    _ = try catalog.createTable("users", .NODE_TABLE, 1);
    
    const table = catalog.getTable("users");
    try std.testing.expect(table != null);
    try std.testing.expectEqualStrings("users", table.?.name);
    
    const missing = catalog.getTable("missing");
    try std.testing.expect(missing == null);
}

test "catalog drop table" {
    const allocator = std.testing.allocator;
    
    var catalog = Catalog.init(allocator);
    defer catalog.deinit();
    
    _ = try catalog.createTable("users", .NODE_TABLE, 1);
    try std.testing.expectEqual(@as(usize, 1), catalog.numTables());
    
    try catalog.dropTable("users", 2);
    try std.testing.expectEqual(@as(usize, 0), catalog.numTables());
}

test "catalog create index" {
    const allocator = std.testing.allocator;
    
    var catalog = Catalog.init(allocator);
    defer catalog.deinit();
    
    const table = try catalog.createTable("users", .NODE_TABLE, 1);
    try table.addColumn(ColumnDefinition.init(0, "id", 6));
    
    const cols = [_]u32{0};
    const index = try catalog.createIndex("users_pk", table.table_id, .PRIMARY, &cols, 1);
    
    try std.testing.expectEqual(@as(u64, 1), index.index_id);
    
    const found = catalog.getIndex("users_pk");
    try std.testing.expect(found != null);
}

test "catalog version" {
    const allocator = std.testing.allocator;
    
    var catalog = Catalog.init(allocator);
    defer catalog.deinit();
    
    try std.testing.expectEqual(@as(u64, 0), catalog.getVersion());
    
    _ = try catalog.createTable("t1", .NODE_TABLE, 1);
    try std.testing.expectEqual(@as(u64, 1), catalog.getVersion());
    
    _ = try catalog.createTable("t2", .NODE_TABLE, 1);
    try std.testing.expectEqual(@as(u64, 2), catalog.getVersion());
}
