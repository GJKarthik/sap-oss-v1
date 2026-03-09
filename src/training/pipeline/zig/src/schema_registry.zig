const std = @import("std");

pub const DataType = enum {
    NVARCHAR,
    TIMESTAMP,
    DECIMAL,
    INTEGER,
    BIGINT,
    BOOLEAN,
    DATE,
    UNKNOWN,

    pub fn fromString(s: []const u8) DataType {
        const upper = blk: {
            var buf: [64]u8 = undefined;
            const len = @min(s.len, 63);
            for (0..len) |i| {
                buf[i] = std.ascii.toUpper(s[i]);
            }
            break :blk buf[0..len];
        };
        if (std.mem.eql(u8, upper, "NVARCHAR")) return .NVARCHAR;
        if (std.mem.eql(u8, upper, "TIMESTAMP")) return .TIMESTAMP;
        if (std.mem.eql(u8, upper, "DECIMAL")) return .DECIMAL;
        if (std.mem.eql(u8, upper, "INTEGER")) return .INTEGER;
        if (std.mem.eql(u8, upper, "BIGINT")) return .BIGINT;
        if (std.mem.eql(u8, upper, "BOOLEAN")) return .BOOLEAN;
        if (std.mem.eql(u8, upper, "DATE")) return .DATE;
        return .UNKNOWN;
    }
};

pub const Column = struct {
    name: []const u8,
    data_type: DataType,
    description: []const u8,
    is_primary_key: bool,
    valid_values: []const []const u8,
};

pub const HierarchyLevel = struct {
    level: u8,
    name: []const u8,
    values: []const []const u8,
};

pub const Domain = enum {
    TREASURY,
    ESG,
    PERFORMANCE,
};

pub const Table = struct {
    name: []const u8,
    schema_name: []const u8,
    domain: Domain,
    columns: []const Column,
    hierarchy_levels: []const HierarchyLevel,
    row_count: usize,
    description: []const u8,
};

pub const JoinPath = struct {
    from_table: []const u8,
    from_column: []const u8,
    to_table: []const u8,
    to_column: []const u8,
    join_type: enum { INNER, LEFT, CROSS },
};

pub const SchemaRegistry = struct {
    allocator: std.mem.Allocator,
    tables: std.ArrayList(Table),
    join_paths: std.ArrayList(JoinPath),

    pub fn init(allocator: std.mem.Allocator) SchemaRegistry {
        return .{
            .allocator = allocator,
            .tables = .empty,
            .join_paths = .empty,
        };
    }

    pub fn deinit(self: *SchemaRegistry) void {
        self.tables.deinit(self.allocator);
        self.join_paths.deinit(self.allocator);
    }

    pub fn addTable(self: *SchemaRegistry, table: Table) !void {
        try self.tables.append(self.allocator, table);
    }

    pub fn findTable(self: *const SchemaRegistry, name: []const u8) ?*const Table {
        for (self.tables.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    pub fn tableCount(self: *const SchemaRegistry) usize {
        return self.tables.items.len;
    }
};

test "DataType fromString" {
    try std.testing.expectEqual(DataType.NVARCHAR, DataType.fromString("NVARCHAR"));
    try std.testing.expectEqual(DataType.TIMESTAMP, DataType.fromString("TIMESTAMP"));
    try std.testing.expectEqual(DataType.DECIMAL, DataType.fromString("DECIMAL"));
    try std.testing.expectEqual(DataType.UNKNOWN, DataType.fromString("BLOB"));
}

test "SchemaRegistry add and find table" {
    const allocator = std.testing.allocator;
    var registry = SchemaRegistry.init(allocator);
    defer registry.deinit();

    try registry.addTable(.{
        .name = "BSI_REM_FACT",
        .schema_name = "STG_BCRS",
        .domain = .TREASURY,
        .columns = &.{},
        .hierarchy_levels = &.{},
        .row_count = 0,
        .description = "Basel MI Fact table",
    });

    const found = registry.findTable("BSI_REM_FACT");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("STG_BCRS", found.?.schema_name);

    const not_found = registry.findTable("NONEXISTENT");
    try std.testing.expect(not_found == null);
}

