//! Logical Plan - Logical Query Plan Representation
//!
//! Converted from: kuzu/src/planner/plan/*.cpp
//!
//! Purpose:
//! Defines logical operators for query planning.
//! Represents high-level query operations before physical optimization.

const std = @import("std");
const common = @import("../common/common.zig");
const expression = @import("../expression/expression.zig");

const LogicalType = common.LogicalType;
const Expression = expression.Expression;

/// Logical operator type
pub const LogicalOperatorType = enum {
    // Scan
    SCAN,
    INDEX_SCAN,
    
    // Selection
    FILTER,
    
    // Projection
    PROJECTION,
    
    // Join
    HASH_JOIN,
    CROSS_PRODUCT,
    
    // Aggregation
    AGGREGATE,
    
    // Sorting
    ORDER_BY,
    TOP_K,
    
    // Set operations
    UNION,
    INTERSECT,
    EXCEPT,
    
    // Limit
    LIMIT,
    SKIP,
    
    // DML
    INSERT,
    DELETE,
    UPDATE,
    
    // DDL
    CREATE_TABLE,
    DROP_TABLE,
    
    // Graph
    EXTEND,
    RECURSIVE_EXTEND,
    PATH_PROPERTY_PROBE,
    
    // Utility
    FLATTEN,
    DISTINCT,
    UNWIND,
};

/// Schema - describes output columns
pub const Schema = struct {
    allocator: std.mem.Allocator,
    column_names: std.ArrayList([]const u8),
    column_types: std.ArrayList(LogicalType),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .column_names = std.ArrayList([]const u8).init(allocator),
            .column_types = std.ArrayList(LogicalType).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.column_names.deinit();
        self.column_types.deinit();
    }
    
    pub fn addColumn(self: *Self, name: []const u8, col_type: LogicalType) !void {
        try self.column_names.append(name);
        try self.column_types.append(col_type);
    }
    
    pub fn getNumColumns(self: *const Self) usize {
        return self.column_names.items.len;
    }
    
    pub fn getColumnIdx(self: *const Self, name: []const u8) ?usize {
        for (self.column_names.items, 0..) |col_name, i| {
            if (std.mem.eql(u8, col_name, name)) {
                return i;
            }
        }
        return null;
    }
};

/// Logical operator node
pub const LogicalOperator = struct {
    allocator: std.mem.Allocator,
    operator_type: LogicalOperatorType,
    schema: Schema,
    children: std.ArrayList(*LogicalOperator),
    
    // Specific data by type
    table_name: ?[]const u8,
    expressions: std.ArrayList(*Expression),
    join_condition: ?*Expression,
    filter_expression: ?*Expression,
    limit_count: ?u64,
    skip_count: ?u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, operator_type: LogicalOperatorType) Self {
        return .{
            .allocator = allocator,
            .operator_type = operator_type,
            .schema = Schema.init(allocator),
            .children = std.ArrayList(*LogicalOperator).init(allocator),
            .table_name = null,
            .expressions = std.ArrayList(*Expression).init(allocator),
            .join_condition = null,
            .filter_expression = null,
            .limit_count = null,
            .skip_count = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit();
        self.schema.deinit();
        self.expressions.deinit();
    }
    
    pub fn addChild(self: *Self, child: *LogicalOperator) !void {
        try self.children.append(child);
    }
    
    pub fn getChild(self: *const Self, idx: usize) ?*LogicalOperator {
        if (idx >= self.children.items.len) return null;
        return self.children.items[idx];
    }
    
    pub fn getNumChildren(self: *const Self) usize {
        return self.children.items.len;
    }
    
    pub fn addExpression(self: *Self, expr: *Expression) !void {
        try self.expressions.append(expr);
    }
    
    pub fn setTableName(self: *Self, name: []const u8) void {
        self.table_name = name;
    }
    
    pub fn setFilter(self: *Self, filter: *Expression) void {
        self.filter_expression = filter;
    }
    
    pub fn setLimit(self: *Self, limit: u64) void {
        self.limit_count = limit;
    }
    
    pub fn setSkip(self: *Self, skip: u64) void {
        self.skip_count = skip;
    }
};

/// Logical plan - root of operator tree
pub const LogicalPlan = struct {
    allocator: std.mem.Allocator,
    root: ?*LogicalOperator,
    estimated_cardinality: u64,
    estimated_cost: f64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .root = null,
            .estimated_cardinality = 0,
            .estimated_cost = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        if (self.root) |r| {
            r.deinit();
            self.allocator.destroy(r);
        }
    }
    
    pub fn setRoot(self: *Self, root: *LogicalOperator) void {
        self.root = root;
    }
    
    pub fn getRoot(self: *const Self) ?*LogicalOperator {
        return self.root;
    }
    
    /// Check if plan is empty
    pub fn isEmpty(self: *const Self) bool {
        return self.root == null;
    }
    
    /// Get plan depth (max depth of operator tree)
    pub fn getDepth(self: *const Self) u32 {
        if (self.root) |r| {
            return getOperatorDepth(r);
        }
        return 0;
    }
    
    fn getOperatorDepth(op: *LogicalOperator) u32 {
        var max_child_depth: u32 = 0;
        for (op.children.items) |child| {
            const child_depth = getOperatorDepth(child);
            if (child_depth > max_child_depth) {
                max_child_depth = child_depth;
            }
        }
        return max_child_depth + 1;
    }
};

/// Logical plan factory
pub const LogicalPlanFactory = struct {
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    pub fn createScan(self: *Self, table_name: []const u8) !*LogicalOperator {
        const op = try self.allocator.create(LogicalOperator);
        op.* = LogicalOperator.init(self.allocator, .SCAN);
        op.setTableName(table_name);
        return op;
    }
    
    pub fn createFilter(self: *Self, child: *LogicalOperator, filter: *Expression) !*LogicalOperator {
        const op = try self.allocator.create(LogicalOperator);
        op.* = LogicalOperator.init(self.allocator, .FILTER);
        try op.addChild(child);
        op.setFilter(filter);
        return op;
    }
    
    pub fn createProjection(self: *Self, child: *LogicalOperator) !*LogicalOperator {
        const op = try self.allocator.create(LogicalOperator);
        op.* = LogicalOperator.init(self.allocator, .PROJECTION);
        try op.addChild(child);
        return op;
    }
    
    pub fn createHashJoin(self: *Self, left: *LogicalOperator, right: *LogicalOperator, condition: *Expression) !*LogicalOperator {
        const op = try self.allocator.create(LogicalOperator);
        op.* = LogicalOperator.init(self.allocator, .HASH_JOIN);
        try op.addChild(left);
        try op.addChild(right);
        op.join_condition = condition;
        return op;
    }
    
    pub fn createAggregate(self: *Self, child: *LogicalOperator) !*LogicalOperator {
        const op = try self.allocator.create(LogicalOperator);
        op.* = LogicalOperator.init(self.allocator, .AGGREGATE);
        try op.addChild(child);
        return op;
    }
    
    pub fn createOrderBy(self: *Self, child: *LogicalOperator) !*LogicalOperator {
        const op = try self.allocator.create(LogicalOperator);
        op.* = LogicalOperator.init(self.allocator, .ORDER_BY);
        try op.addChild(child);
        return op;
    }
    
    pub fn createLimit(self: *Self, child: *LogicalOperator, limit: u64) !*LogicalOperator {
        const op = try self.allocator.create(LogicalOperator);
        op.* = LogicalOperator.init(self.allocator, .LIMIT);
        try op.addChild(child);
        op.setLimit(limit);
        return op;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "schema" {
    const allocator = std.testing.allocator;
    
    var schema = Schema.init(allocator);
    defer schema.deinit();
    
    try schema.addColumn("id", .INT64);
    try schema.addColumn("name", .STRING);
    
    try std.testing.expectEqual(@as(usize, 2), schema.getNumColumns());
    try std.testing.expectEqual(@as(usize, 0), schema.getColumnIdx("id").?);
    try std.testing.expectEqual(@as(usize, 1), schema.getColumnIdx("name").?);
}

test "logical operator" {
    const allocator = std.testing.allocator;
    
    var op = LogicalOperator.init(allocator, .SCAN);
    defer op.deinit();
    
    op.setTableName("users");
    try std.testing.expect(std.mem.eql(u8, "users", op.table_name.?));
}

test "logical plan" {
    const allocator = std.testing.allocator;
    
    var plan = LogicalPlan.init(allocator);
    defer plan.deinit();
    
    try std.testing.expect(plan.isEmpty());
    
    var factory = LogicalPlanFactory.init(allocator);
    const scan = try factory.createScan("users");
    plan.setRoot(scan);
    
    try std.testing.expect(!plan.isEmpty());
    try std.testing.expectEqual(@as(u32, 1), plan.getDepth());
}

test "logical plan factory" {
    const allocator = std.testing.allocator;
    
    var factory = LogicalPlanFactory.init(allocator);
    
    const scan = try factory.createScan("users");
    const limit = try factory.createLimit(scan, 10);
    
    defer limit.deinit();
    defer allocator.destroy(limit);
    
    try std.testing.expectEqual(LogicalOperatorType.LIMIT, limit.operator_type);
    try std.testing.expectEqual(@as(u64, 10), limit.limit_count.?);
}