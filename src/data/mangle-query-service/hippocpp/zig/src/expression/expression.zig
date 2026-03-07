//! Expression System - Query Expression AST
//!
//! Converted from: kuzu/src/expression/*.cpp
//!
//! Purpose:
//! Defines the expression system for query evaluation.
//! Supports literals, column refs, operators, functions.

const std = @import("std");
const common = @import("../common/common.zig");

const LogicalType = common.LogicalType;

/// Expression type enumeration
pub const ExpressionType = enum {
    // Literals
    LITERAL,
    PARAMETER,
    
    // References
    COLUMN,
    PROPERTY,
    VARIABLE,
    
    // Comparison
    EQUALS,
    NOT_EQUALS,
    GREATER_THAN,
    GREATER_THAN_EQUALS,
    LESS_THAN,
    LESS_THAN_EQUALS,
    
    // Logical
    AND,
    OR,
    NOT,
    
    // Arithmetic
    ADD,
    SUBTRACT,
    MULTIPLY,
    DIVIDE,
    MODULO,
    NEGATE,
    
    // String
    CONCAT,
    LIKE,
    NOT_LIKE,
    
    // Null
    IS_NULL,
    IS_NOT_NULL,
    COALESCE,
    
    // Aggregate
    COUNT,
    COUNT_STAR,
    SUM,
    AVG,
    MIN,
    MAX,
    COLLECT,
    
    // List
    LIST,
    LIST_EXTRACT,
    LIST_SLICE,
    
    // Case
    CASE_WHEN,
    CASE_ELSE,
    
    // Function
    FUNCTION,
    SCALAR_FUNCTION,
    AGGREGATE_FUNCTION,
    
    // Subquery
    SUBQUERY,
    EXISTS,
    IN,
    
    // Graph
    NODE,
    REL,
    PATH,
    INTERNAL_ID,
    LABEL,
    
    // Cast
    CAST,
};

/// Literal value union
pub const LiteralValue = union(enum) {
    null_val: void,
    bool_val: bool,
    int64_val: i64,
    float64_val: f64,
    string_val: []const u8,
    
    pub fn toBool(self: LiteralValue) ?bool {
        return switch (self) {
            .bool_val => |v| v,
            else => null,
        };
    }
    
    pub fn toInt64(self: LiteralValue) ?i64 {
        return switch (self) {
            .int64_val => |v| v,
            .float64_val => |v| @intFromFloat(v),
            .bool_val => |v| @intFromBool(v),
            else => null,
        };
    }
    
    pub fn toFloat64(self: LiteralValue) ?f64 {
        return switch (self) {
            .float64_val => |v| v,
            .int64_val => |v| @floatFromInt(v),
            else => null,
        };
    }
};

/// Expression node
pub const Expression = struct {
    allocator: std.mem.Allocator,
    expr_type: ExpressionType,
    data_type: LogicalType,
    alias: ?[]const u8,
    children: std.ArrayList(*Expression),
    
    // Specific data based on type
    literal_value: ?LiteralValue,
    column_name: ?[]const u8,
    table_name: ?[]const u8,
    function_name: ?[]const u8,
    parameter_idx: ?u32,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, expr_type: ExpressionType, data_type: LogicalType) Self {
        return .{
            .allocator = allocator,
            .expr_type = expr_type,
            .data_type = data_type,
            .alias = null,
            .children = std.ArrayList(*Expression).init(allocator),
            .literal_value = null,
            .column_name = null,
            .table_name = null,
            .function_name = null,
            .parameter_idx = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        // Recursively free children
        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit();
    }
    
    pub fn addChild(self: *Self, child: *Expression) !void {
        try self.children.append(child);
    }
    
    pub fn getChild(self: *const Self, idx: usize) ?*Expression {
        if (idx >= self.children.items.len) return null;
        return self.children.items[idx];
    }
    
    pub fn getNumChildren(self: *const Self) usize {
        return self.children.items.len;
    }
    
    pub fn setAlias(self: *Self, alias: []const u8) void {
        self.alias = alias;
    }
    
    pub fn isAggregate(self: *const Self) bool {
        return switch (self.expr_type) {
            .COUNT, .COUNT_STAR, .SUM, .AVG, .MIN, .MAX, .COLLECT, .AGGREGATE_FUNCTION => true,
            else => false,
        };
    }
    
    pub fn hasSubquery(self: *const Self) bool {
        if (self.expr_type == .SUBQUERY or self.expr_type == .EXISTS) return true;
        for (self.children.items) |child| {
            if (child.hasSubquery()) return true;
        }
        return false;
    }
};

/// Expression factory
pub const ExpressionFactory = struct {
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    pub fn createLiteral(self: *Self, value: LiteralValue, data_type: LogicalType) !*Expression {
        const expr = try self.allocator.create(Expression);
        expr.* = Expression.init(self.allocator, .LITERAL, data_type);
        expr.literal_value = value;
        return expr;
    }
    
    pub fn createIntLiteral(self: *Self, value: i64) !*Expression {
        return self.createLiteral(.{ .int64_val = value }, .INT64);
    }
    
    pub fn createFloatLiteral(self: *Self, value: f64) !*Expression {
        return self.createLiteral(.{ .float64_val = value }, .DOUBLE);
    }
    
    pub fn createBoolLiteral(self: *Self, value: bool) !*Expression {
        return self.createLiteral(.{ .bool_val = value }, .BOOLEAN);
    }
    
    pub fn createStringLiteral(self: *Self, value: []const u8) !*Expression {
        return self.createLiteral(.{ .string_val = value }, .STRING);
    }
    
    pub fn createNullLiteral(self: *Self) !*Expression {
        return self.createLiteral(.{ .null_val = {} }, .ANY);
    }
    
    pub fn createColumn(self: *Self, column_name: []const u8, table_name: ?[]const u8, data_type: LogicalType) !*Expression {
        const expr = try self.allocator.create(Expression);
        expr.* = Expression.init(self.allocator, .COLUMN, data_type);
        expr.column_name = column_name;
        expr.table_name = table_name;
        return expr;
    }
    
    pub fn createComparison(self: *Self, cmp_type: ExpressionType, left: *Expression, right: *Expression) !*Expression {
        const expr = try self.allocator.create(Expression);
        expr.* = Expression.init(self.allocator, cmp_type, .BOOLEAN);
        try expr.addChild(left);
        try expr.addChild(right);
        return expr;
    }
    
    pub fn createAnd(self: *Self, left: *Expression, right: *Expression) !*Expression {
        const expr = try self.allocator.create(Expression);
        expr.* = Expression.init(self.allocator, .AND, .BOOLEAN);
        try expr.addChild(left);
        try expr.addChild(right);
        return expr;
    }
    
    pub fn createOr(self: *Self, left: *Expression, right: *Expression) !*Expression {
        const expr = try self.allocator.create(Expression);
        expr.* = Expression.init(self.allocator, .OR, .BOOLEAN);
        try expr.addChild(left);
        try expr.addChild(right);
        return expr;
    }
    
    pub fn createNot(self: *Self, child: *Expression) !*Expression {
        const expr = try self.allocator.create(Expression);
        expr.* = Expression.init(self.allocator, .NOT, .BOOLEAN);
        try expr.addChild(child);
        return expr;
    }
    
    pub fn createArithmetic(self: *Self, op_type: ExpressionType, left: *Expression, right: *Expression) !*Expression {
        const result_type = inferArithmeticType(left.data_type, right.data_type);
        const expr = try self.allocator.create(Expression);
        expr.* = Expression.init(self.allocator, op_type, result_type);
        try expr.addChild(left);
        try expr.addChild(right);
        return expr;
    }
    
    pub fn createAggregate(self: *Self, agg_type: ExpressionType, child: ?*Expression, result_type: LogicalType) !*Expression {
        const expr = try self.allocator.create(Expression);
        expr.* = Expression.init(self.allocator, agg_type, result_type);
        if (child) |c| {
            try expr.addChild(c);
        }
        return expr;
    }
    
    pub fn createFunction(self: *Self, name: []const u8, args: []*Expression, result_type: LogicalType) !*Expression {
        const expr = try self.allocator.create(Expression);
        expr.* = Expression.init(self.allocator, .FUNCTION, result_type);
        expr.function_name = name;
        for (args) |arg| {
            try expr.addChild(arg);
        }
        return expr;
    }
    
    pub fn createIsNull(self: *Self, child: *Expression) !*Expression {
        const expr = try self.allocator.create(Expression);
        expr.* = Expression.init(self.allocator, .IS_NULL, .BOOLEAN);
        try expr.addChild(child);
        return expr;
    }
    
    pub fn createCast(self: *Self, child: *Expression, target_type: LogicalType) !*Expression {
        const expr = try self.allocator.create(Expression);
        expr.* = Expression.init(self.allocator, .CAST, target_type);
        try expr.addChild(child);
        return expr;
    }
    
    fn inferArithmeticType(left: LogicalType, right: LogicalType) LogicalType {
        if (left == .DOUBLE or right == .DOUBLE) return .DOUBLE;
        if (left == .FLOAT or right == .FLOAT) return .FLOAT;
        if (left == .INT64 or right == .INT64) return .INT64;
        return .INT32;
    }
};

/// Expression visitor interface
pub const ExpressionVisitor = struct {
    visitFn: *const fn (*ExpressionVisitor, *Expression) anyerror!void,
    context: ?*anyopaque,
    
    pub fn visit(self: *ExpressionVisitor, expr: *Expression) !void {
        try self.visitFn(self, expr);
        for (expr.children.items) |child| {
            try self.visit(child);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "literal value" {
    const int_val = LiteralValue{ .int64_val = 42 };
    try std.testing.expectEqual(@as(i64, 42), int_val.toInt64().?);
    
    const float_val = LiteralValue{ .float64_val = 3.14 };
    try std.testing.expect(float_val.toFloat64().? > 3.0);
    
    const bool_val = LiteralValue{ .bool_val = true };
    try std.testing.expect(bool_val.toBool().?);
}

test "expression factory literals" {
    const allocator = std.testing.allocator;
    
    var factory = ExpressionFactory.init(allocator);
    
    const int_expr = try factory.createIntLiteral(100);
    defer int_expr.deinit();
    defer allocator.destroy(int_expr);
    
    try std.testing.expectEqual(ExpressionType.LITERAL, int_expr.expr_type);
    try std.testing.expectEqual(LogicalType.INT64, int_expr.data_type);
    try std.testing.expectEqual(@as(i64, 100), int_expr.literal_value.?.toInt64().?);
}

test "expression factory column" {
    const allocator = std.testing.allocator;
    
    var factory = ExpressionFactory.init(allocator);
    
    const col_expr = try factory.createColumn("id", "users", .INT64);
    defer col_expr.deinit();
    defer allocator.destroy(col_expr);
    
    try std.testing.expectEqual(ExpressionType.COLUMN, col_expr.expr_type);
    try std.testing.expect(std.mem.eql(u8, "id", col_expr.column_name.?));
    try std.testing.expect(std.mem.eql(u8, "users", col_expr.table_name.?));
}

test "expression comparison" {
    const allocator = std.testing.allocator;
    
    var factory = ExpressionFactory.init(allocator);
    
    const left = try factory.createIntLiteral(10);
    const right = try factory.createIntLiteral(20);
    const cmp = try factory.createComparison(.LESS_THAN, left, right);
    defer cmp.deinit();
    defer allocator.destroy(cmp);
    
    try std.testing.expectEqual(ExpressionType.LESS_THAN, cmp.expr_type);
    try std.testing.expectEqual(LogicalType.BOOLEAN, cmp.data_type);
    try std.testing.expectEqual(@as(usize, 2), cmp.getNumChildren());
}

test "expression aggregate check" {
    const allocator = std.testing.allocator;
    
    var factory = ExpressionFactory.init(allocator);
    
    const sum_expr = try factory.createAggregate(.SUM, null, .INT64);
    defer sum_expr.deinit();
    defer allocator.destroy(sum_expr);
    
    try std.testing.expect(sum_expr.isAggregate());
    
    const lit_expr = try factory.createIntLiteral(1);
    defer lit_expr.deinit();
    defer allocator.destroy(lit_expr);
    
    try std.testing.expect(!lit_expr.isAggregate());
}