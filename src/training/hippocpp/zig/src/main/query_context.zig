//! Query Context - Full Query Execution Pipeline
//!
//! Converted from: kuzu/src/main/query_context.cpp
//!
//! Purpose:
//! Integrates parser, binder, planner, optimizer, and processor
//! to execute queries end-to-end.

const std = @import("std");
const parser_mod = @import("parser");
const binder_mod = @import("binder");
const planner_mod = @import("planner");
const optimizer_mod = @import("optimizer");
const processor_mod = @import("processor");
const logical_plan_mod = @import("logical_plan");

const Parser = parser_mod.Parser;
const Binder = binder_mod.Binder;
const QueryPlanner = planner_mod.QueryPlanner;
const QueryOptimizer = optimizer_mod.QueryOptimizer;
const PhysicalPlanGenerator = optimizer_mod.PhysicalPlanGenerator;
const QueryProcessor = processor_mod.QueryProcessor;
const QueryResult = processor_mod.QueryResult;
const LogicalPlan = logical_plan_mod.LogicalPlan;

/// Prepared statement
pub const PreparedStatement = struct {
    allocator: std.mem.Allocator,
    query: []const u8,
    logical_plan: ?LogicalPlan,
    is_valid: bool,
    error_message: ?[]const u8,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, query: []const u8) Self {
        return .{
            .allocator = allocator,
            .query = query,
            .logical_plan = null,
            .is_valid = false,
            .error_message = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        if (self.logical_plan) |*plan| {
            plan.deinit();
        }
    }
    
    pub fn setError(self: *Self, msg: []const u8) void {
        self.is_valid = false;
        self.error_message = msg;
    }
};

/// Query context - manages query execution
pub const QueryContext = struct {
    allocator: std.mem.Allocator,
    binder: Binder,
    planner: QueryPlanner,
    optimizer: QueryOptimizer,
    generator: PhysicalPlanGenerator,
    processor: QueryProcessor,
    query_count: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .binder = Binder.init(allocator),
            .planner = QueryPlanner.init(allocator),
            .optimizer = QueryOptimizer.init(allocator),
            .generator = PhysicalPlanGenerator.init(allocator),
            .processor = QueryProcessor.init(allocator),
            .query_count = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.binder.deinit(self.allocator);
        self.planner.deinit(self.allocator);
        self.optimizer.deinit(self.allocator);
        self.processor.deinit(self.allocator);
    }
    
    /// Execute a query string
    pub fn query(self: *Self, sql: []const u8) !QueryResult {
        self.query_count += 1;
        
        // Phase 1: Parse
        var parser = Parser.init(self.allocator, sql);
        var parsed = try parser.parse();
        defer parsed.deinit(self.allocator);
        
        // Phase 2: Bind
        var bound = try self.binder.bind(&parsed);
        defer bound.deinit(self.allocator);
        
        // Phase 3: Plan
        var plan = try self.planner.createPlan(&bound);
        defer plan.deinit(self.allocator);
        
        // Phase 4: Optimize
        try self.optimizer.optimize(&plan);
        
        // Phase 5: Generate physical plan
        const physical = try self.generator.generate(&plan);
        
        // Phase 6: Execute
        if (physical) |phys_op| {
            defer {
                phys_op.deinit();
                self.allocator.destroy(phys_op);
            }
            return self.processor.execute(phys_op);
        }
        
        return QueryResult.init(self.allocator);
    }
    
    /// Prepare a statement for later execution
    pub fn prepare(self: *Self, sql: []const u8) !PreparedStatement {
        var stmt = PreparedStatement.init(self.allocator, sql);
        errdefer stmt.deinit();
        
        // Parse
        var parser = Parser.init(self.allocator, sql);
        var parsed = parser.parse() catch |err| {
            stmt.setError(@errorName(err));
            return stmt;
        };
        defer parsed.deinit(self.allocator);
        
        // Bind
        var bound = self.binder.bind(&parsed) catch |err| {
            stmt.setError(@errorName(err));
            return stmt;
        };
        defer bound.deinit(self.allocator);
        
        // Plan
        stmt.logical_plan = self.planner.createPlan(&bound) catch |err| {
            stmt.setError(@errorName(err));
            return stmt;
        };
        
        stmt.is_valid = true;
        return stmt;
    }
    
    /// Execute a prepared statement
    pub fn executePrepared(self: *Self, stmt: *PreparedStatement) !QueryResult {
        if (!stmt.is_valid) {
            var result = QueryResult.init(self.allocator);
            result.setError("Invalid prepared statement");
            return result;
        }
        
        self.query_count += 1;
        
        if (stmt.logical_plan) |*plan| {
            // Optimize
            try self.optimizer.optimize(plan);
            
            // Generate and execute
            const physical = try self.generator.generate(plan);
            if (physical) |phys_op| {
                defer {
                    phys_op.deinit();
                    self.allocator.destroy(phys_op);
                }
                return self.processor.execute(phys_op);
            }
        }
        
        return QueryResult.init(self.allocator);
    }
    
    /// Get query statistics
    pub fn getQueryCount(self: *const Self) u64 {
        return self.query_count;
    }
};

/// Query result set (wrapper for iteration)
pub const QueryResultSet = struct {
    result: QueryResult,
    current_row: u64,
    
    const Self = @This();
    
    pub fn init(result: QueryResult) Self {
        return .{
            .result = result,
            .current_row = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.result.deinit(self.allocator);
    }
    
    pub fn hasNext(self: *const Self) bool {
        return self.current_row < self.result.num_tuples;
    }
    
    pub fn next(self: *Self) bool {
        if (self.hasNext()) {
            self.current_row += 1;
            return true;
        }
        return false;
    }
    
    pub fn getNumColumns(self: *const Self) usize {
        return self.result.getNumColumns();
    }
    
    pub fn getNumRows(self: *const Self) u64 {
        return self.result.num_tuples;
    }
    
    pub fn isSuccess(self: *const Self) bool {
        return self.result.success;
    }
    
    pub fn getErrorMessage(self: *const Self) ?[]const u8 {
        return self.result.error_message;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "prepared statement" {
    const allocator = std.testing.allocator;
    
    var stmt = PreparedStatement.init(allocator, "SELECT * FROM users");
    defer stmt.deinit(std.testing.allocator);
    
    try std.testing.expect(!stmt.is_valid);
    try std.testing.expect(std.mem.eql(u8, "SELECT * FROM users", stmt.query));
}

test "query context init" {
    const allocator = std.testing.allocator;
    
    var ctx = QueryContext.init(allocator);
    defer ctx.deinit(std.testing.allocator);
    
    try std.testing.expectEqual(@as(u64, 0), ctx.getQueryCount());
}

test "query result set" {
    const allocator = std.testing.allocator;
    
    var result = QueryResult.init(allocator);
    var rs = QueryResultSet.init(result);
    defer rs.deinit(std.testing.allocator);
    
    try std.testing.expect(rs.isSuccess());
    try std.testing.expect(!rs.hasNext());
}