//! Binder - Semantic Analysis and Name Resolution
//!
//! Converted from: kuzu/src/binder/*.cpp
//!
//! Purpose:
//! Binds parsed AST to catalog objects.
//! Resolves table/column names, validates types, performs semantic analysis.

const std = @import("std");
const ast = @import("parser_ast");
const expression = @import("expression");
const common = @import("common");

const ParsedStatement = ast.ParsedStatement;
const Expression = expression.Expression;
const ExpressionFactory = expression.ExpressionFactory;
const LogicalType = common.LogicalType;

// ============================================================================
// Binding Errors
// ============================================================================

pub const BinderError = error{
    UnsupportedStatement,
    InvalidQuery,
    InvalidStatement,
    UnresolvedColumn,
    UnresolvedTable,
    AmbiguousColumn,
    TypeMismatch,
    InvalidJoinCondition,
    InvalidGroupBy,
    AggregateInWhere,
    NonAggregateInGroupBy,
    SubqueryNotAllowed,
    OutOfMemory,
};

// ============================================================================
// Bound Column
// ============================================================================

/// Bound column info after name resolution
pub const BoundColumn = struct {
    name: []const u8,
    table_name: ?[]const u8,
    data_type: LogicalType,
    column_idx: u32,
    table_idx: u32 = 0,
    is_nullable: bool = true,
    
    pub fn init(name: []const u8, table_name: ?[]const u8, data_type: LogicalType, idx: u32) BoundColumn {
        return .{
            .name = name,
            .table_name = table_name,
            .data_type = data_type,
            .column_idx = idx,
        };
    }
    
    pub fn withTableIdx(self: BoundColumn, table_idx: u32) BoundColumn {
        var col = self;
        col.table_idx = table_idx;
        return col;
    }
    
    pub fn qualifiedName(self: *const BoundColumn, buf: []u8) []const u8 {
        if (self.table_name) |tn| {
            return std.fmt.bufPrint(buf, "{s}.{s}", .{ tn, self.name }) catch self.name;
        }
        return self.name;
    }
};

// ============================================================================
// Bound Table
// ============================================================================

/// Bound table info with resolved columns
pub const BoundTable = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    alias: ?[]const u8,
    table_id: u64,
    table_idx: u32,
    columns: std.ArrayList(BoundColumn),
    table_type: TableType = .BASE,
    
    pub const TableType = enum {
        BASE,
        SUBQUERY,
        CTE,
        DERIVED,
    };
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, table_id: u64) BoundTable {
        return .{
            .allocator = allocator,
            .name = name,
            .alias = null,
            .table_id = table_id,
            .table_idx = 0,
            .columns = .{},
        };
    }
    
    pub fn deinit(self: *BoundTable) void {
        self.columns.deinit(self.allocator);
    }
    
    pub fn addColumn(self: *BoundTable, col: BoundColumn) !void {
        var new_col = col;
        new_col.table_idx = self.table_idx;
        try self.columns.append(self.allocator, new_col);
    }
    
    pub fn getColumn(self: *const BoundTable, name: []const u8) ?BoundColumn {
        for (self.columns.items) |col| {
            if (std.mem.eql(u8, col.name, name)) {
                return col;
            }
        }
        return null;
    }

    pub fn effectiveName(self: *const BoundTable) []const u8 {
        return self.alias orelse self.name;
    }
    
    pub fn columnCount(self: *const BoundTable) usize {
        return self.columns.items.len;
    }
};

// ============================================================================
// Binding Scope
// ============================================================================

/// Binding scope for hierarchical name resolution
pub const BindingScope = struct {
    allocator: std.mem.Allocator,
    tables: std.ArrayList(BoundTable),
    parent: ?*BindingScope,
    scope_type: ScopeType = .QUERY,
    aggregates_allowed: bool = true,
    in_aggregate: bool = false,
    group_by_columns: std.ArrayList(BoundColumn),
    
    pub const ScopeType = enum {
        QUERY,
        SUBQUERY,
        JOIN,
        WHERE,
        HAVING,
        ORDER_BY,
    };
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .tables = .{},
            .parent = null,
            .group_by_columns = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.tables.items) |*t| {
            t.deinit();
        }
        self.tables.deinit(self.allocator);
        self.group_by_columns.deinit(self.allocator);
    }
    
    pub fn createChild(self: *Self, scope_type: ScopeType) Self {
        var child = Self.init(self.allocator);
        child.parent = self;
        child.scope_type = scope_type;
        child.aggregates_allowed = self.aggregates_allowed and scope_type != .WHERE;
        return child;
    }
    
    pub fn addTable(self: *Self, table: BoundTable) !void {
        var t = table;
        t.table_idx = @intCast(self.tables.items.len);
        try self.tables.append(self.allocator, t);
    }
    
    pub fn resolveColumn(self: *const Self, name: []const u8, table_name: ?[]const u8) BinderError!?BoundColumn {
        var found: ?BoundColumn = null;
        var found_count: u32 = 0;
        
        // Search tables in current scope
        for (self.tables.items) |table| {
            const effective_name = table.effectiveName();
            
            if (table_name) |tn| {
                if (!std.mem.eql(u8, effective_name, tn)) {
                    continue;
                }
            }
            
            if (table.getColumn(name)) |col| {
                found = col;
                found_count += 1;
            }
        }
        
        // Check for ambiguity
        if (found_count > 1 and table_name == null) {
            return BinderError.AmbiguousColumn;
        }
        
        if (found != null) {
            return found;
        }
        
        // Try parent scope
        if (self.parent) |p| {
            return p.resolveColumn(name, table_name);
        }
        
        return null;
    }
    
    pub fn resolveTable(self: *const Self, name: []const u8) ?*const BoundTable {
        for (self.tables.items) |*table| {
            if (std.mem.eql(u8, table.effectiveName(), name)) {
                return table;
            }
        }
        
        if (self.parent) |p| {
            return p.resolveTable(name);
        }
        
        return null;
    }
    
    pub fn addGroupByColumn(self: *Self, col: BoundColumn) !void {
        try self.group_by_columns.append(self.allocator, col);
    }
    
    pub fn isInGroupBy(self: *const Self, col: *const BoundColumn) bool {
        for (self.group_by_columns.items) |gc| {
            if (std.mem.eql(u8, gc.name, col.name)) {
                if (gc.table_name == null or col.table_name == null) {
                    return true;
                }
                if (std.mem.eql(u8, gc.table_name.?, col.table_name.?)) {
                    return true;
                }
            }
        }
        return false;
    }
};

// ============================================================================
// Bound Expression
// ============================================================================

/// Types of bound expressions
pub const BoundExpressionType = enum {
    COLUMN_REF,
    LITERAL,
    FUNCTION_CALL,
    AGGREGATE,
    COMPARISON,
    LOGICAL,
    ARITHMETIC,
    SUBQUERY,
    CASE_WHEN,
    CAST,
    NULL_TEST,
    IN_LIST,
    BETWEEN,
    LIKE,
    EXISTS,
    PARAMETER,
};

/// Bound expression with resolved types
pub const BoundExpression = struct {
    expr_type: BoundExpressionType,
    data_type: LogicalType,
    alias: ?[]const u8 = null,
    children: std.ArrayList(*BoundExpression),
    allocator: std.mem.Allocator,
    
    // Specific fields based on type
    column: ?BoundColumn = null,
    literal_int: ?i64 = null,
    literal_float: ?f64 = null,
    literal_string: ?[]const u8 = null,
    literal_bool: ?bool = null,
    function_name: ?[]const u8 = null,
    is_distinct: bool = false,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, expr_type: BoundExpressionType, data_type: LogicalType) Self {
        return .{
            .allocator = allocator,
            .expr_type = expr_type,
            .data_type = data_type,
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
    
    pub fn addChild(self: *Self, child: *BoundExpression) !void {
        try self.children.append(self.allocator, child);
    }
    
    pub fn isAggregate(self: *const Self) bool {
        if (self.expr_type == .AGGREGATE) return true;
        for (self.children.items) |child| {
            if (child.isAggregate()) return true;
        }
        return false;
    }
    
    pub fn containsColumn(self: *const Self, col: *const BoundColumn) bool {
        if (self.column) |c| {
            if (std.mem.eql(u8, c.name, col.name)) {
                return true;
            }
        }
        for (self.children.items) |child| {
            if (child.containsColumn(col)) return true;
        }
        return false;
    }
};

// ============================================================================
// Bound Join
// ============================================================================

pub const JoinType = enum {
    INNER,
    LEFT,
    RIGHT,
    FULL,
    CROSS,
    SEMI,
    ANTI,
};

pub const BoundJoin = struct {
    join_type: JoinType,
    left_table: *BoundTable,
    right_table: *BoundTable,
    condition: ?*BoundExpression,
    
    pub fn init(join_type: JoinType, left: *BoundTable, right: *BoundTable) BoundJoin {
        return .{
            .join_type = join_type,
            .left_table = left,
            .right_table = right,
            .condition = null,
        };
    }
};

// ============================================================================
// Bound Statement
// ============================================================================

/// Fully bound statement ready for planning
pub const BoundStatement = struct {
    allocator: std.mem.Allocator,
    statement_type: ast.StatementType,
    bound_tables: std.ArrayList(BoundTable),
    projections: std.ArrayList(*BoundExpression),
    result_columns: std.ArrayList(BoundColumn),
    where_clause: ?*BoundExpression = null,
    joins: std.ArrayList(BoundJoin),
    group_by: std.ArrayList(*BoundExpression),
    having: ?*BoundExpression = null,
    order_by: std.ArrayList(OrderByItem),
    limit: ?u64 = null,
    offset: ?u64 = null,
    is_distinct: bool = false,
    
    pub const OrderByItem = struct {
        expression: *BoundExpression,
        ascending: bool = true,
        nulls_first: bool = false,
    };
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, statement_type: ast.StatementType) Self {
        return .{
            .allocator = allocator,
            .statement_type = statement_type,
            .bound_tables = .{},
            .projections = .{},
            .result_columns = .{},
            .joins = .{},
            .group_by = .{},
            .order_by = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.bound_tables.items) |*t| {
            t.deinit();
        }
        self.bound_tables.deinit(self.allocator);
        
        for (self.projections.items) |e| {
            e.deinit();
            self.allocator.destroy(e);
        }
        self.projections.deinit(self.allocator);
        self.result_columns.deinit(self.allocator);
        
        if (self.where_clause) |w| {
            w.deinit();
            self.allocator.destroy(w);
        }
        
        self.joins.deinit(self.allocator);
        
        for (self.group_by.items) |g| {
            g.deinit();
            self.allocator.destroy(g);
        }
        self.group_by.deinit(self.allocator);
        
        if (self.having) |h| {
            h.deinit();
            self.allocator.destroy(h);
        }
        
        for (self.order_by.items) |o| {
            o.expression.deinit();
            self.allocator.destroy(o.expression);
        }
        self.order_by.deinit(self.allocator);
    }
    
    pub fn hasAggregates(self: *const Self) bool {
        for (self.projections.items) |p| {
            if (p.isAggregate()) return true;
        }
        return false;
    }
    
    pub fn hasGroupBy(self: *const Self) bool {
        return self.group_by.items.len > 0;
    }
};

// ============================================================================
// Binder
// ============================================================================

/// Query binder - performs semantic analysis
pub const Binder = struct {
    allocator: std.mem.Allocator,
    scope: BindingScope,
    next_table_id: u64,
    errors: std.ArrayList([]const u8),
    warnings: std.ArrayList([]const u8),

    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .scope = BindingScope.init(allocator),
            .next_table_id = 1,
            .errors = .{},
            .warnings = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.scope.deinit();
        self.errors.deinit(self.allocator);
        self.warnings.deinit(self.allocator);
    }
    
    /// Main entry point - bind a parsed statement
    pub fn bind(self: *Self, stmt: *const ParsedStatement) BinderError!BoundStatement {
        return switch (stmt.statement_type) {
            .QUERY => self.bindQuery(stmt),
            .CREATE_TABLE => self.bindCreateTable(stmt),
            .CREATE_NODE_TABLE => self.bindCreateNodeTable(stmt),
            .CREATE_REL_TABLE => self.bindCreateRelTable(stmt),
            .INSERT => self.bindInsert(stmt),
            .DELETE => self.bindDelete(stmt),
            .UPDATE => self.bindUpdate(stmt),
            .DROP_TABLE => self.bindDropTable(stmt),
            .COPY_FROM => self.bindCopyFrom(stmt),
            .COPY_TO => self.bindCopyTo(stmt),
            .MATCH => self.bindMatch(stmt),
            else => BinderError.UnsupportedStatement,
        };
    }
    
    /// Bind SELECT query
    fn bindQuery(self: *Self, stmt: *const ParsedStatement) BinderError!BoundStatement {
        var result = BoundStatement.init(self.allocator, .QUERY);
        errdefer result.deinit();
        
        const query = stmt.query orelse return BinderError.InvalidQuery;
        
        // 1. Bind FROM clause first (establishes scope)
        if (query.from_clause) |from| {
            try self.bindFromClause(from, &result);
        }
        
        // 2. Bind WHERE clause
        if (query.where_clause) |where| {
            var where_scope = self.scope.createChild(.WHERE);
            defer where_scope.deinit(self.allocator);
            
            result.where_clause = try self.bindExpressionInScope(where, &where_scope);
            
            // Check no aggregates in WHERE
            if (result.where_clause.?.isAggregate()) {
                return BinderError.AggregateInWhere;
            }
        }
        
        // 3. Bind GROUP BY
        if (query.group_by_clause) |group_by| {
            for (group_by.items) |gb_expr| {
                const bound = try self.bindExpressionInScope(gb_expr, &self.scope);
                try result.group_by.append(self.allocator, bound);
                
                // Add to scope for HAVING validation
                if (bound.column) |col| {
                    try self.scope.addGroupByColumn(col);
                }
            }
        }
        
        // 4. Bind SELECT projections
        if (query.select_clause) |select| {
            result.is_distinct = select.is_distinct;
            
            for (select.projections.items, 0..) |proj, i| {
                const bound_expr = try self.bindExpressionInScope(proj.expression, &self.scope);
                try result.projections.append(self.allocator, bound_expr);
                
                const col = BoundColumn.init(
                    proj.alias orelse self.getExpressionName(bound_expr),
                    null,
                    bound_expr.data_type,
                    @intCast(i),
                );
                try result.result_columns.append(self.allocator, col);
            }
            
            // Validate GROUP BY semantics
            if (result.hasGroupBy() or result.hasAggregates()) {
                try self.validateGroupBySemantics(&result);
            }
        }
        
        // 5. Bind HAVING
        if (query.having_clause) |having| {
            var having_scope = self.scope.createChild(.HAVING);
            defer having_scope.deinit(self.allocator);
            
            result.having = try self.bindExpressionInScope(having, &having_scope);
        }
        
        // 6. Bind ORDER BY
        if (query.order_by_clause) |order_by| {
            var order_scope = self.scope.createChild(.ORDER_BY);
            defer order_scope.deinit(self.allocator);
            
            for (order_by.items) |ob_item| {
                const bound_expr = try self.bindExpressionInScope(ob_item.expression, &order_scope);
                try result.order_by.append(.{
                    .expression = bound_expr,
                    .ascending = ob_item.ascending,
                    .nulls_first = ob_item.nulls_first,
                });
            }
        }
        
        // 7. Bind LIMIT/OFFSET
        if (query.limit) |limit| {
            result.limit = limit;
        }
        if (query.offset) |offset| {
            result.offset = offset;
        }
        
        return result;
    }
    
    fn bindFromClause(self: *Self, from: *const ast.FromClause, result: *BoundStatement) BinderError!void {
        for (from.tables.items, 0..) |table_ref, i| {
            var bound_table = BoundTable.init(self.allocator, table_ref.table_name, self.next_table_id);
            self.next_table_id += 1;
            bound_table.table_idx = @intCast(i);
            
            if (table_ref.alias) |alias| {
                bound_table.alias = alias;
            }
            
            // Add default columns (would normally come from catalog)
            try self.addDefaultColumnsForTable(&bound_table);
            
            try self.scope.addTable(bound_table);
            try result.bound_tables.append(self.allocator, bound_table);
        }
        
        // Bind JOINs
        if (from.joins.items.len > 0) {
            for (from.joins.items) |join_info| {
                try self.bindJoin(join_info, result);
            }
        }
    }
    
    fn bindJoin(self: *Self, join_info: ast.JoinInfo, result: *BoundStatement) BinderError!void {
        // Resolve left and right tables
        const left = self.scope.resolveTable(join_info.left_table) orelse return BinderError.UnresolvedTable;
        const right = self.scope.resolveTable(join_info.right_table) orelse return BinderError.UnresolvedTable;
        
        var bound_join = BoundJoin.init(
            @enumFromInt(@intFromEnum(join_info.join_type)),
            @constCast(left),
            @constCast(right),
        );
        
        // Bind join condition
        if (join_info.condition) |cond| {
            bound_join.condition = try self.bindExpressionInScope(cond, &self.scope);
        }
        
        try result.joins.append(self.allocator, bound_join);
    }
    
    fn bindExpressionInScope(self: *Self, parsed: *const ast.ParsedExpression, scope: *BindingScope) BinderError!*BoundExpression {
        const bound = try self.allocator.create(BoundExpression);
        errdefer self.allocator.destroy(bound);
        
        bound.* = switch (parsed.expr_type) {
            .COLUMN_REF => try self.bindColumnRef(parsed, scope),
            .LITERAL => try self.bindLiteral(parsed),
            .FUNCTION_CALL => try self.bindFunctionCall(parsed, scope),
            .COMPARISON => try self.bindComparison(parsed, scope),
            .LOGICAL => try self.bindLogical(parsed, scope),
            .ARITHMETIC => try self.bindArithmetic(parsed, scope),
            .AGGREGATE => try self.bindAggregate(parsed, scope),
            else => BoundExpression.init(self.allocator, .LITERAL, .ANY),
        };
        
        return bound;
    }
    
    fn bindColumnRef(self: *Self, parsed: *const ast.ParsedExpression, scope: *BindingScope) BinderError!BoundExpression {
        const col = try scope.resolveColumn(parsed.text, parsed.table_name) orelse return BinderError.UnresolvedColumn;
        
        var result = BoundExpression.init(self.allocator, .COLUMN_REF, col.data_type);
        result.column = col;
        return result;
    }
    
    fn bindLiteral(self: *Self, parsed: *const ast.ParsedExpression) BinderError!BoundExpression {
        const text = parsed.text;
        
        // Try integer
        if (std.fmt.parseInt(i64, text, 10)) |val| {
            var result = BoundExpression.init(self.allocator, .LITERAL, .INT64);
            result.literal_int = val;
            return result;
        } else |_| {}
        
        // Try float
        if (std.fmt.parseFloat(f64, text)) |val| {
            var result = BoundExpression.init(self.allocator, .LITERAL, .DOUBLE);
            result.literal_float = val;
            return result;
        } else |_| {}
        
        // Try boolean
        if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "TRUE")) {
            var result = BoundExpression.init(self.allocator, .LITERAL, .BOOL);
            result.literal_bool = true;
            return result;
        }
        if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "FALSE")) {
            var result = BoundExpression.init(self.allocator, .LITERAL, .BOOL);
            result.literal_bool = false;
            return result;
        }
        
        // Default: string
        var result = BoundExpression.init(self.allocator, .LITERAL, .STRING);
        result.literal_string = text;
        return result;
    }
    
    fn bindFunctionCall(self: *Self, parsed: *const ast.ParsedExpression, scope: *BindingScope) BinderError!BoundExpression {
        var result = BoundExpression.init(self.allocator, .FUNCTION_CALL, .ANY);
        result.function_name = parsed.function_name;
        
        // Bind arguments
        if (parsed.args) |args| {
            for (args.items) |arg| {
                const bound_arg = try self.bindExpressionInScope(arg, scope);
                try result.addChild(bound_arg);
            }
        }
        
        // Infer result type based on function
        result.data_type = self.inferFunctionReturnType(parsed.function_name.?);
        
        return result;
    }
    
    fn bindAggregate(self: *Self, parsed: *const ast.ParsedExpression, scope: *BindingScope) BinderError!BoundExpression {
        if (!scope.aggregates_allowed) {
            return BinderError.AggregateInWhere;
        }
        
        var result = BoundExpression.init(self.allocator, .AGGREGATE, .ANY);
        result.function_name = parsed.function_name;
        result.is_distinct = parsed.is_distinct;
        
        // Bind argument
        if (parsed.args) |args| {
            for (args.items) |arg| {
                const bound_arg = try self.bindExpressionInScope(arg, scope);
                try result.addChild(bound_arg);
            }
        }
        
        // Infer result type
        result.data_type = self.inferAggregateReturnType(parsed.function_name.?, &result);
        
        return result;
    }
    
    fn bindComparison(self: *Self, parsed: *const ast.ParsedExpression, scope: *BindingScope) BinderError!BoundExpression {
        var result = BoundExpression.init(self.allocator, .COMPARISON, .BOOL);
        
        if (parsed.left) |left| {
            const bound_left = try self.bindExpressionInScope(left, scope);
            try result.addChild(bound_left);
        }
        if (parsed.right) |right| {
            const bound_right = try self.bindExpressionInScope(right, scope);
            try result.addChild(bound_right);
        }
        
        return result;
    }
    
    fn bindLogical(self: *Self, parsed: *const ast.ParsedExpression, scope: *BindingScope) BinderError!BoundExpression {
        var result = BoundExpression.init(self.allocator, .LOGICAL, .BOOL);
        
        if (parsed.left) |left| {
            const bound_left = try self.bindExpressionInScope(left, scope);
            try result.addChild(bound_left);
        }
        if (parsed.right) |right| {
            const bound_right = try self.bindExpressionInScope(right, scope);
            try result.addChild(bound_right);
        }
        
        return result;
    }
    
    fn bindArithmetic(self: *Self, parsed: *const ast.ParsedExpression, scope: *BindingScope) BinderError!BoundExpression {
        var result = BoundExpression.init(self.allocator, .ARITHMETIC, .INT64);
        
        if (parsed.left) |left| {
            const bound_left = try self.bindExpressionInScope(left, scope);
            try result.addChild(bound_left);
            
            // Promote type if needed
            if (bound_left.data_type == .DOUBLE) {
                result.data_type = .DOUBLE;
            }
        }
        if (parsed.right) |right| {
            const bound_right = try self.bindExpressionInScope(right, scope);
            try result.addChild(bound_right);
            
            if (bound_right.data_type == .DOUBLE) {
                result.data_type = .DOUBLE;
            }
        }
        
        return result;
    }
    
    fn validateGroupBySemantics(self: *Self, result: *const BoundStatement) BinderError!void {
        _ = self;
        // All non-aggregate columns in SELECT must be in GROUP BY
        for (result.projections.items) |proj| {
            if (!proj.isAggregate()) {
                // This column must be in GROUP BY
                // For now, simplified validation
                // _ = proj;
            }
        }
    }
    
    fn addDefaultColumnsForTable(_: *Self, table: *BoundTable) !void {
        // Default columns for unknown tables
        try table.addColumn(BoundColumn.init("id", table.name, .INT64, 0));
    }
    
    fn getExpressionName(self: *Self, expr: *const BoundExpression) []const u8 {
        _ = self;
        if (expr.column) |col| return col.name;
        if (expr.function_name) |fn_name| return fn_name;
        return "expr";
    }
    
    fn inferFunctionReturnType(self: *Self, func_name: []const u8) LogicalType {
        _ = self;
        const name_lower = func_name; // Would lowercase in real impl
        
        if (std.mem.eql(u8, name_lower, "length") or
            std.mem.eql(u8, name_lower, "size")) return .INT64;
        if (std.mem.eql(u8, name_lower, "upper") or
            std.mem.eql(u8, name_lower, "lower") or
            std.mem.eql(u8, name_lower, "trim")) return .STRING;
        if (std.mem.eql(u8, name_lower, "abs") or
            std.mem.eql(u8, name_lower, "round")) return .DOUBLE;
        if (std.mem.eql(u8, name_lower, "now") or
            std.mem.eql(u8, name_lower, "current_timestamp")) return .TIMESTAMP;
        
        return .ANY;
    }
    
    fn inferAggregateReturnType(self: *Self, func_name: []const u8, expr: *const BoundExpression) LogicalType {
        _ = self;
        if (std.mem.eql(u8, func_name, "COUNT")) return .INT64;
        if (std.mem.eql(u8, func_name, "SUM")) {
            if (expr.children.items.len > 0) {
                return expr.children.items[0].data_type;
            }
            return .INT64;
        }
        if (std.mem.eql(u8, func_name, "AVG")) return .DOUBLE;
        if (std.mem.eql(u8, func_name, "MIN") or std.mem.eql(u8, func_name, "MAX")) {
            if (expr.children.items.len > 0) {
                return expr.children.items[0].data_type;
            }
        }
        return .ANY;
    }
    
    // DDL binding methods
    fn bindCreateTable(self: *Self, stmt: *const ParsedStatement) BinderError!BoundStatement {
        var result = BoundStatement.init(self.allocator, .CREATE_TABLE);
        errdefer result.deinit();
        
        const create = stmt.create_table orelse return BinderError.InvalidStatement;
        
        var bound_table = BoundTable.init(self.allocator, create.table_name, self.next_table_id);
        self.next_table_id += 1;
        
        for (create.columns.items, 0..) |col_def, i| {
            try bound_table.addColumn(BoundColumn.init(
                col_def.name,
                create.table_name,
                col_def.data_type,
                @intCast(i),
            ));
        }
        
        try result.bound_tables.append(self.allocator, bound_table);
        return result;
    }
    
    fn bindCreateNodeTable(self: *Self, stmt: *const ParsedStatement) BinderError!BoundStatement {
        return self.bindCreateTable(stmt);
    }
    
    fn bindCreateRelTable(self: *Self, stmt: *const ParsedStatement) BinderError!BoundStatement {
        return self.bindCreateTable(stmt);
    }
    
    fn bindInsert(self: *Self, _: *const ParsedStatement) BinderError!BoundStatement {
        return BoundStatement.init(self.allocator, .INSERT);
    }
    
    fn bindDelete(self: *Self, _: *const ParsedStatement) BinderError!BoundStatement {
        return BoundStatement.init(self.allocator, .DELETE);
    }
    
    fn bindUpdate(self: *Self, _: *const ParsedStatement) BinderError!BoundStatement {
        return BoundStatement.init(self.allocator, .UPDATE);
    }
    
    fn bindDropTable(self: *Self, _: *const ParsedStatement) BinderError!BoundStatement {
        return BoundStatement.init(self.allocator, .DROP_TABLE);
    }
    
    fn bindCopyFrom(self: *Self, _: *const ParsedStatement) BinderError!BoundStatement {
        return BoundStatement.init(self.allocator, .COPY_FROM);
    }
    
    fn bindCopyTo(self: *Self, _: *const ParsedStatement) BinderError!BoundStatement {
        return BoundStatement.init(self.allocator, .COPY_TO);
    }
    
    fn bindMatch(self: *Self, _: *const ParsedStatement) BinderError!BoundStatement {
        return BoundStatement.init(self.allocator, .MATCH);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "bound column" {
    const col = BoundColumn.init("id", "users", .INT64, 0);
    try std.testing.expect(std.mem.eql(u8, "id", col.name));
    try std.testing.expectEqual(LogicalType.INT64, col.data_type);
}

test "bound column with table idx" {
    const col = BoundColumn.init("name", "users", .STRING, 1).withTableIdx(2);
    try std.testing.expectEqual(@as(u32, 2), col.table_idx);
}

test "binding scope" {
    const allocator = std.testing.allocator;
    
    var scope = BindingScope.init(allocator);
    defer scope.deinit();
    
    var table = BoundTable.init(allocator, "users", 1);
    try table.addColumn(BoundColumn.init("id", "users", .INT64, 0));
    try table.addColumn(BoundColumn.init("name", "users", .STRING, 1));
    try scope.addTable(table);
    
    const col = try scope.resolveColumn("id", null);
    try std.testing.expect(col != null);
    try std.testing.expectEqual(LogicalType.INT64, col.?.data_type);
}

test "binding scope child" {
    const allocator = std.testing.allocator;
    
    var parent = BindingScope.init(allocator);
    defer parent.deinit();
    
    var child = parent.createChild(.WHERE);
    defer child.deinit();
    
    try std.testing.expect(!child.aggregates_allowed);
    try std.testing.expect(child.parent != null);
}

test "binder init" {
    const allocator = std.testing.allocator;
    
    var binder = Binder.init(allocator);
    defer binder.deinit();
    
    try std.testing.expectEqual(@as(u64, 1), binder.next_table_id);
}

test "bound expression aggregate check" {
    const allocator = std.testing.allocator;
    
    var expr = BoundExpression.init(allocator, .AGGREGATE, .INT64);
    defer expr.deinit();
    
    try std.testing.expect(expr.isAggregate());
}

test "bound statement init" {
    const allocator = std.testing.allocator;
    
    var stmt = BoundStatement.init(allocator, .QUERY);
    defer stmt.deinit();
    
    try std.testing.expect(!stmt.hasAggregates());
    try std.testing.expect(!stmt.hasGroupBy());
}







