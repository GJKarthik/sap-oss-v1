//! AST - Abstract Syntax Tree for Parsed Statements
//!
//! Converted from: kuzu/src/parser/*.cpp
//!
//! Purpose:
//! Defines AST nodes for parsed SQL/Cypher statements.
//! Used by parser to represent query structure before binding.

const std = @import("std");
const common = @import("common");

/// Statement type
pub const StatementType = enum {
    // Query
    QUERY,
    
    // DML
    CREATE,
    INSERT,
    DELETE,
    UPDATE,
    MERGE,
    
    // DDL
    CREATE_TABLE,
    DROP_TABLE,
    ALTER_TABLE,
    CREATE_INDEX,
    DROP_INDEX,
    CREATE_TYPE,
    
    // Transaction
    BEGIN_TRANSACTION,
    COMMIT,
    ROLLBACK,
    
    // Utility
    EXPLAIN,
    PROFILE,
    COPY,
    EXPORT,
    IMPORT,
    CALL,
    
    // Cypher-specific
    MATCH,
    RETURN,
    WITH,
    UNWIND,
    CREATE_NODE,
    CREATE_REL,
};

/// Join type in query
pub const JoinType = enum {
    INNER,
    LEFT,
    RIGHT,
    FULL,
    CROSS,
    NATURAL,
    SEMI,
    ANTI,
    MARK,
};
pub const ParsedJoinType = enum {
    INNER,
    LEFT,
    RIGHT,
    FULL,
    CROSS,
};

/// Sort order
pub const ParsedSortOrder = enum {
    ASC,
    DESC,
};

/// Parsed expression (pre-binding)
pub const ExpressionKind = enum {
    LITERAL,
    COLUMN,
    FUNCTION,
    PROPERTY,
    PARAMETER,
    SUBQUERY,
    EXISTS,
    CASE,
    COMPARISON,
    LOGICAL,
    NOT,
    IS_NULL,
    IS_NOT_NULL,
    AGGREGATE,
    STAR,
    ARITHMETIC,
    NULL_TEST,
    IN,
    BETWEEN,
    CAST,
    UNKNOWN,
};

pub const ParsedExpression = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    alias: ?[]const u8,
    expr_type: ExpressionKind,
    left: ?*ParsedExpression = null,
    right: ?*ParsedExpression = null,
    subquery: ?*ParsedExpression = null,
    args: std.ArrayList(*ParsedExpression),
    children: std.ArrayList(*ParsedExpression),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, text: []const u8) Self {
        return .{
            .allocator = allocator,
            .text = text,
            .alias = null,
            .expr_type = .UNKNOWN,
            .left = null,
            .right = null,
            .args = .{},
            .children = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit(self.allocator);
    }
    
    pub fn addChild(self: *Self, child: *ParsedExpression) !void {
        try self.children.append(self.allocator, child);
    }
};

/// Column definition for CREATE TABLE
pub const ColumnDefinition = struct {
    name: []const u8,
    data_type: common.LogicalType,
    is_nullable: bool,
    is_primary_key: bool,
    is_unique: bool,
    default_value: ?[]const u8,

    pub fn init(name: []const u8, data_type: common.LogicalType) ColumnDefinition {
        return .{
            .name = name,
            .data_type = data_type,
            .is_nullable = true,
            .is_primary_key = false,
            .is_unique = false,
            .default_value = null,
        };
    }
};

/// Table reference in FROM clause
pub const TableReference = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8,
    alias: ?[]const u8,
    schema_name: ?[]const u8,
    
    pub fn init(allocator: std.mem.Allocator, table_name: []const u8) TableReference {
        return .{
            .allocator = allocator,
            .table_name = table_name,
            .alias = null,
            .schema_name = null,
        };
    }
};

/// Order by item
pub const OrderByItem = struct {
    expression: *ParsedExpression,
    order: ParsedSortOrder,
    nulls_first: bool,
    
    pub fn init(expr: *ParsedExpression, order: ParsedSortOrder) OrderByItem {
        return .{
            .expression = expr,
            .order = order,
            .nulls_first = order == .DESC,
        };
    }
};

/// SELECT clause
pub const SelectClause = struct {
    allocator: std.mem.Allocator,
    projections: std.ArrayList(*ParsedExpression),
    is_distinct: bool,
    
    pub fn init(allocator: std.mem.Allocator) SelectClause {
        return .{
            .allocator = allocator,
            .projections = .{},
            .is_distinct = false,
        };
    }
    
    pub fn deinit(self: *SelectClause) void {
        for (self.projections.items) |proj| {
            proj.deinit();
            self.allocator.destroy(proj);
        }
        self.projections.deinit(self.allocator);
    }
    
    pub fn addProjection(self: *SelectClause, expr: *ParsedExpression) !void {
        try self.projections.append(self.allocator, expr);
    }
};

/// FROM clause
pub const JoinInfo = struct {
    join_type: JoinType = .INNER,
    left_table: []const u8 = "",
    right_table: []const u8 = "",
    condition: ?*ParsedExpression = null,
};

pub const FromClause = struct {
    allocator: std.mem.Allocator,
    tables: std.ArrayList(TableReference),
    joins: std.ArrayList(JoinInfo),

    pub fn init(allocator: std.mem.Allocator) FromClause {
        return .{
            .allocator = allocator,
            .tables = .{},
            .joins = .{},
        };
    }

    pub fn deinit(self: *FromClause) void {
        self.tables.deinit(self.allocator);
        self.joins.deinit(self.allocator);
    }

    pub fn addTable(self: *FromClause, table: TableReference) !void {
        try self.tables.append(self.allocator, table);
    }

    pub fn addJoin(self: *FromClause, join: JoinInfo) !void {
        try self.joins.append(self.allocator, join);
    }
};

/// Query statement (SELECT)
pub const QueryStatement = struct {
    allocator: std.mem.Allocator,
    select_clause: ?SelectClause,
    from_clause: ?FromClause,
    where_clause: ?*ParsedExpression,
    group_by: std.ArrayList(*ParsedExpression),
    having_clause: ?*ParsedExpression,
    order_by: std.ArrayList(OrderByItem),
    limit: ?u64,
    offset: ?u64,
    is_optional: bool,

    pub fn init(allocator: std.mem.Allocator) QueryStatement {
        return .{
            .allocator = allocator,
            .select_clause = null,
            .from_clause = null,
            .where_clause = null,
            .group_by = .{},
            .having_clause = null,
            .order_by = .{},
            .limit = null,
            .offset = null,
            .is_optional = false,
        };
    }
    
    pub fn deinit(self: *QueryStatement) void {
        if (self.select_clause) |*sc| sc.deinit();
        if (self.from_clause) |*fc| fc.deinit();
        if (self.where_clause) |wc| {
            wc.deinit();
            self.allocator.destroy(wc);
        }
        for (self.group_by.items) |gb| {
            gb.deinit();
            self.allocator.destroy(gb);
        }
        self.group_by.deinit(self.allocator);
        if (self.having_clause) |hc| {
            hc.deinit();
            self.allocator.destroy(hc);
        }
        for (self.order_by.items) |ob| {
            ob.expression.deinit();
            self.allocator.destroy(ob.expression);
        }
        self.order_by.deinit(self.allocator);
    }
};

/// CREATE TABLE statement
pub const CreateTableStatement = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8,
    columns: std.ArrayList(ColumnDefinition),
    if_not_exists: bool,
    
    pub fn init(allocator: std.mem.Allocator, table_name: []const u8) CreateTableStatement {
        return .{
            .allocator = allocator,
            .table_name = table_name,
            .columns = .{},
            .if_not_exists = false,
        };
    }
    
    pub fn deinit(self: *CreateTableStatement) void {
        self.columns.deinit(self.allocator);
    }
    
    pub fn addColumn(self: *CreateTableStatement, col: ColumnDefinition) !void {
        try self.columns.append(self.allocator, col);
    }
};

/// INSERT statement
pub const InsertStatement = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8,
    columns: std.ArrayList([]const u8),
    values: std.ArrayList(*ParsedExpression),
    
    pub fn init(allocator: std.mem.Allocator, table_name: []const u8) InsertStatement {
        return .{
            .allocator = allocator,
            .table_name = table_name,
            .columns = .{},
            .values = .{},
        };
    }
    
    pub fn deinit(self: *InsertStatement) void {
        self.columns.deinit(self.allocator);
        for (self.values.items) |v| {
            v.deinit();
            self.allocator.destroy(v);
        }
        self.values.deinit(self.allocator);
    }
};

/// UPDATE assignment
pub const Assignment = struct {
    column: []const u8,
    value: ?*ParsedExpression = null,
};

/// UPDATE statement
pub const UpdateStatement = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8,
    assignments: std.ArrayList(Assignment),
    where_clause: ?*ParsedExpression = null,

    pub fn init(allocator: std.mem.Allocator, table_name: []const u8) UpdateStatement {
        return .{
            .allocator = allocator,
            .table_name = table_name,
            .assignments = .{},
        };
    }

    pub fn deinit(self: *UpdateStatement) void {
        self.assignments.deinit(self.allocator);
    }
};

/// DELETE statement
pub const DeleteStatement = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8,
    where_clause: ?*ParsedExpression,
    
    pub fn init(allocator: std.mem.Allocator, table_name: []const u8) DeleteStatement {
        return .{
            .allocator = allocator,
            .table_name = table_name,
            .where_clause = null,
        };
    }
    
    pub fn deinit(self: *DeleteStatement) void {
        if (self.where_clause) |wc| {
            wc.deinit();
            self.allocator.destroy(wc);
        }
    }
};

/// Parsed statement (union of all statement types)
pub const ParsedStatement = struct {
    allocator: std.mem.Allocator,
    statement_type: StatementType,
    query: ?QueryStatement,
    create_table: ?CreateTableStatement,
    insert: ?InsertStatement,
    update: ?UpdateStatement = null,
    delete: ?DeleteStatement,
    match: ?QueryStatement = null,
    target_table: ?[]const u8 = null,
    index_name: ?[]const u8 = null,
    drop_table_name: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, statement_type: StatementType) ParsedStatement {
        return .{
            .allocator = allocator,
            .statement_type = statement_type,
            .query = null,
            .create_table = null,
            .insert = null,
            .delete = null,
            .match = null,
            .target_table = null,
            .index_name = null,
            .drop_table_name = null,
        };
    }
    
    pub fn deinit(self: *ParsedStatement) void {
        if (self.query) |*q| q.deinit();
        if (self.create_table) |*ct| ct.deinit();
        if (self.insert) |*i| i.deinit();
        if (self.delete) |*d| d.deinit();
    }
    
    pub fn createQuery(allocator: std.mem.Allocator) ParsedStatement {
        var stmt = ParsedStatement.init(allocator, .QUERY);
        stmt.query = QueryStatement.init(allocator);
        return stmt;
    }
    
    pub fn createCreateTable(allocator: std.mem.Allocator, table_name: []const u8) ParsedStatement {
        var stmt = ParsedStatement.init(allocator, .CREATE_TABLE);
        stmt.create_table = CreateTableStatement.init(allocator, table_name);
        return stmt;
    }

    pub fn createInsert(allocator: std.mem.Allocator, table_name: []const u8) ParsedStatement {
        var stmt = ParsedStatement.init(allocator, .INSERT);
        stmt.target_table = table_name;
        return stmt;
    }

    pub fn createUpdate(allocator: std.mem.Allocator, table_name: []const u8) ParsedStatement {
        var stmt = ParsedStatement.init(allocator, .UPDATE);
        stmt.target_table = table_name;
        return stmt;
    }

    pub fn createDelete(allocator: std.mem.Allocator, table_name: []const u8) ParsedStatement {
        var stmt = ParsedStatement.init(allocator, .DELETE);
        stmt.target_table = table_name;
        return stmt;
    }

    pub fn createMatch(allocator: std.mem.Allocator) ParsedStatement {
        var stmt = ParsedStatement.init(allocator, .MATCH);
        stmt.query = QueryStatement.init(allocator);
        return stmt;
    }

    pub fn createIndex(allocator: std.mem.Allocator, index_name: []const u8) ParsedStatement {
        var stmt = ParsedStatement.init(allocator, .CREATE_INDEX);
        stmt.index_name = index_name;
        return stmt;
    }

    pub fn createDropTable(allocator: std.mem.Allocator, table_name: []const u8) ParsedStatement {
        var stmt = ParsedStatement.init(allocator, .DROP_TABLE);
        stmt.drop_table_name = table_name;
        return stmt;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "parsed expression" {
    const allocator = std.testing.allocator;
    
    var expr = ParsedExpression.init(allocator, "x + y");
    defer expr.deinit();
    
    try std.testing.expect(std.mem.eql(u8, "x + y", expr.text));
}

test "column definition" {
    const col = ColumnDefinition.init("id", .INT64);
    try std.testing.expect(std.mem.eql(u8, "id", col.name));
    try std.testing.expectEqual(common.LogicalType.INT64, col.data_type);
    try std.testing.expect(col.is_nullable);
}

test "query statement" {
    const allocator = std.testing.allocator;
    
    var query = QueryStatement.init(allocator);
    defer query.deinit();
    
    query.select_clause = SelectClause.init(allocator);
    query.from_clause = FromClause.init(allocator);
    query.limit = 100;
    
    try std.testing.expectEqual(@as(u64, 100), query.limit.?);
}

test "create table statement" {
    const allocator = std.testing.allocator;
    
    var create = CreateTableStatement.init(allocator, "users");
    defer create.deinit();
    
    try create.addColumn(ColumnDefinition.init("id", .INT64));
    try create.addColumn(ColumnDefinition.init("name", .STRING));
    
    try std.testing.expectEqual(@as(usize, 2), create.columns.items.len);
}

test "parsed statement" {
    const allocator = std.testing.allocator;
    
    var stmt = ParsedStatement.createQuery(allocator);
    defer stmt.deinit();
    
    try std.testing.expectEqual(StatementType.QUERY, stmt.statement_type);
    try std.testing.expect(stmt.query != null);
}