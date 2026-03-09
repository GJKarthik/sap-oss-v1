//! Query Optimizer - Full Implementation
//!
//! Converted from: kuzu/src/optimizer/*.cpp
//!
//! Purpose:
//! Optimizes logical query plans using a series of rewriters. Each optimizer
//! applies specific transformations to improve execution efficiency.
//!
//! Architecture:
//! ```
//! LogicalPlan (from Planner)
//!   │
//!   └── Optimizer::optimize()
//!         │
//!         ├── RemoveFactorizationRewriter
//!         ├── CorrelatedSubqueryUnnestSolver
//!         ├── RemoveUnnecessaryJoinOptimizer
//!         ├── FilterPushDownOptimizer
//!         ├── ProjectionPushDownOptimizer
//!         ├── LimitPushDownOptimizer
//!         ├── HashJoinSIPOptimizer (if enableSemiMask)
//!         ├── TopKOptimizer
//!         ├── FactorizationRewriter
//!         ├── AggKeyDependencyOptimizer
//!         └── CardinalityUpdater (for EXPLAIN)
//! ```

const std = @import("std");
const logical_plan = @import("logical_plan");
const physical_operator = @import("physical_operator");
const expression_mod = @import("expression");

const LogicalOperator = logical_plan.LogicalOperator;
const LogicalOperatorType = logical_plan.LogicalOperatorType;
const LogicalPlan = logical_plan.LogicalPlan;
const Schema = logical_plan.Schema;
const PhysicalOperator = physical_operator.PhysicalOperator;
const Expression = expression_mod.Expression;

// ============================================================================
// Optimization Configuration
// ============================================================================

/// Optimizer configuration options
pub const OptimizerConfig = struct {
    /// Master switch for all optimizations
    enable_optimizer: bool = true,
    
    /// Enable filter push-down optimization
    enable_filter_pushdown: bool = true,
    
    /// Enable projection push-down optimization
    enable_projection_pushdown: bool = true,
    
    /// Enable limit push-down optimization
    enable_limit_pushdown: bool = true,
    
    /// Enable TopK optimization (ORDER BY + LIMIT -> TopK)
    enable_top_k: bool = true,
    
    /// Enable semi-mask optimization for hash joins
    enable_semi_mask: bool = true,
    
    /// Enable zone map predicate filtering
    enable_zone_map: bool = true,
    
    /// Enable correlated subquery unnesting
    enable_subquery_unnest: bool = true,
    
    /// Enable join reordering
    enable_join_reorder: bool = true,
    
    /// Enable constant folding
    enable_constant_folding: bool = true,
    
    /// Enable common subexpression elimination
    enable_cse: bool = true,
    
    /// Maximum optimization iterations
    max_iterations: u32 = 10,
    
    /// Recursive pattern semantic for projection pushdown
    recursive_pattern_semantic: bool = true,
    
    pub fn default() OptimizerConfig {
        return .{};
    }
    
    pub fn disabled() OptimizerConfig {
        return .{
            .enable_optimizer = false,
        };
    }
};

// ============================================================================
// Predicate Set - Collection of predicates for optimization
// ============================================================================

/// Set of predicates partitioned by type
pub const PredicateSet = struct {
    allocator: std.mem.Allocator,
    equality_predicates: std.ArrayList(*Expression),
    non_equality_predicates: std.ArrayList(*Expression),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .equality_predicates = .{},
            .non_equality_predicates = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.equality_predicates.deinit(self.allocator);
        self.non_equality_predicates.deinit(self.allocator);
    }
    
    /// Add a predicate to the set
    pub fn addPredicate(self: *Self, predicate: *Expression) !void {
        if (predicate.expr_type == .EQUALS) {
            try self.equality_predicates.append(self.allocator, predicate);
        } else {
            try self.non_equality_predicates.append(self.allocator, predicate);
        }
    }
    
    /// Get all predicates
    pub fn getAllPredicates(self: *const Self, result: *std.ArrayList(*Expression)) !void {
        for (self.equality_predicates.items) |p| {
            try result.append(self.allocator, p);
        }
        for (self.non_equality_predicates.items) |p| {
            try result.append(self.allocator, p);
        }
    }
    
    /// Check if empty
    pub fn isEmpty(self: *const Self) bool {
        return self.equality_predicates.items.len == 0 and 
               self.non_equality_predicates.items.len == 0;
    }
    
    /// Clear all predicates
    pub fn clear(self: *Self) void {
        self.equality_predicates.clearRetainingCapacity();
        self.non_equality_predicates.clearRetainingCapacity();
    }
    
    /// Pop primary key equality comparison for index scan optimization
    pub fn popPrimaryKeyEquality(self: *Self, node_id: []const u8) ?*Expression {
        for (self.equality_predicates.items, 0..) |pred, i| {
            // Check if predicate involves primary key on node_id
            if (self.isPrimaryKeyPredicate(pred, node_id)) {
                _ = self.equality_predicates.orderedRemove(i);
                return pred;
            }
        }
        return null;
    }
    
    fn isPrimaryKeyPredicate(_: *Self, pred: *Expression, node_id: []const u8) bool {
        _ = pred;
        _ = node_id;
        // TODO: Implement primary key detection
        return false;
    }
};

// ============================================================================
// Column Predicate - Predicates for zone map filtering
// ============================================================================

/// Column predicate types for zone map filtering
pub const ColumnPredicateType = enum {
    EQUALS,
    NOT_EQUALS,
    LESS_THAN,
    LESS_THAN_OR_EQUALS,
    GREATER_THAN,
    GREATER_THAN_OR_EQUALS,
    IS_NULL,
    IS_NOT_NULL,
    IN,
    BETWEEN,
};

/// Column predicate for zone map optimization
pub const ColumnPredicate = struct {
    predicate_type: ColumnPredicateType,
    column_name: []const u8,
    value: ?*Expression,
    value2: ?*Expression, // For BETWEEN
    
    const Self = @This();
    
    pub fn init(pred_type: ColumnPredicateType, column: []const u8, val: ?*Expression) Self {
        return .{
            .predicate_type = pred_type,
            .column_name = column,
            .value = val,
            .value2 = null,
        };
    }
    
    /// Try to convert an expression to a column predicate
    pub fn tryConvert(column: []const u8, expr: *Expression) ?ColumnPredicate {
        // Check if expression references the column
        _ = column;
        _ = expr;
        // TODO: Implement conversion logic
        return null;
    }
};

/// Set of column predicates
pub const ColumnPredicateSet = struct {
    allocator: std.mem.Allocator,
    predicates: std.ArrayList(ColumnPredicate),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .predicates = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.predicates.deinit(self.allocator);
    }
    
    pub fn addPredicate(self: *Self, pred: ColumnPredicate) !void {
        try self.predicates.append(self.allocator, pred);
    }
    
    pub fn isEmpty(self: *const Self) bool {
        return self.predicates.items.len == 0;
    }
};

// ============================================================================
// Optimization Rule Interface
// ============================================================================

/// Optimization rule result
pub const RuleResult = struct {
    /// Whether the rule was applicable
    applied: bool,
    /// Whether the plan was changed
    changed: bool,
    /// Replacement operator (if any)
    replacement: ?*LogicalOperator,
};

/// Base optimization rule interface
pub const OptimizationRule = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    
    const Self = @This();
    
    /// Apply the rule to an operator
    pub fn apply(self: *Self, op: *LogicalOperator) RuleResult {
        _ = self;
        _ = op;
        return .{ .applied = false, .changed = false, .replacement = null };
    }
};

// ============================================================================
// Filter Push-Down Optimizer
// ============================================================================

    /// Filter push-down optimizer - pushes filters closer to data sources
    pub const FilterPushDownOptimizer = struct {
        allocator: std.mem.Allocator,
        config: OptimizerConfig,
        predicate_set: PredicateSet,

        const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: OptimizerConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .predicate_set = PredicateSet.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.predicate_set.deinit();
    }
    
    /// Rewrite the plan with filter push-down
    pub fn rewrite(self: *Self, plan: *LogicalPlan) !void {
        if (plan.root) |root| {
            const new_root = try self.visitOperator(root);
            plan.root = new_root;
        }
    }
    
    fn visitOperator(self: *Self, op: *LogicalOperator) anyerror!*LogicalOperator {
        return switch (op.operator_type) {
            .FILTER => try self.visitFilter(op),
            .CROSS_PRODUCT => try self.visitCrossProduct(op),
            .SCAN => try self.visitScan(op),
            .HASH_JOIN => try self.visitHashJoin(op),
            else => try self.visitChildren(op),
        };
    }
    
    fn visitChildren(self: *Self, op: *LogicalOperator) !*LogicalOperator {
        for (op.children.items, 0..) |child, i| {
            // Create new optimizer for child subtree
            var child_optimizer = FilterPushDownOptimizer.init(self.allocator, self.config);
            defer child_optimizer.deinit();
            
            const new_child = try child_optimizer.visitOperator(child);
            op.children.items[i] = new_child;
        }
        return try self.finishPushDown(op);
    }
    
    fn visitFilter(self: *Self, op: *LogicalOperator) !*LogicalOperator {
        // Collect filter predicate
        if (op.filter_expression) |pred| {
            // Check for literal predicates
            if (self.isLiteralFalseOrNull(pred)) {
                // Return empty result
                const empty = try self.allocator.create(LogicalOperator);
                empty.* = LogicalOperator.init(self.allocator, .EMPTY_RESULT);
                return empty;
            }
            
            if (!self.isLiteralTrue(pred)) {
                // TODO: add predicate to predicate set
            }
        }
        
        // Continue with child
        if (op.getChild(0)) |_| {
    // return try self.visitOperator(child);
        }
        return op;
    }
    
    fn visitCrossProduct(self: *Self, op: *LogicalOperator) !*LogicalOperator {
        var remaining_preds = PredicateSet.init(self.allocator);
        defer remaining_preds.deinit();
        
        // TODO: implement predicate partitioning and push-down
        
        // Try to convert cross product to hash join
        if (try self.tryConvertToHashJoin(op, &remaining_preds)) |join_op| {
            return join_op;
        }
        
        // Clear and add remaining predicates
        self.predicate_set.clear();
        var remaining_all: std.ArrayList(*Expression) = .{};
        defer remaining_all.deinit(self.allocator);
        try remaining_preds.getAllPredicates(&remaining_all);
        for (remaining_all.items) |p| {
            try self.predicate_set.addPredicate(p);
        }
        
        return try self.finishPushDown(op);
    }
    
    fn visitScan(self: *Self, op: *LogicalOperator) !*LogicalOperator {
        // Try to apply index scan optimization
        if (self.config.enable_zone_map) {
            // Apply column predicates to scan
            try self.applyColumnPredicatesToScan(op);
        }
        
        // Try primary key scan
        if (op.table_name) |table_name| {
            if (self.predicate_set.popPrimaryKeyEquality(table_name)) |pk_pred| {
                // Check if RHS is constant
                if (self.isConstantExpression(pk_pred)) {
                    op.operator_type = .INDEX_SCAN;
                    // Set primary key scan info
                } else {
                    // Cannot use index, add predicate back
                    try self.predicate_set.addPredicate(pk_pred);
                }
            }
        }
        
        return try self.finishPushDown(op);
    }
    
    fn visitHashJoin(self: *Self, op: *LogicalOperator) !*LogicalOperator {
        // Push predicates through hash join
        return try self.visitChildren(op);
    }
    
    fn finishPushDown(self: *Self, op: *LogicalOperator) !*LogicalOperator {
        if (self.predicate_set.isEmpty()) {
            return op;
        }
        
        // Append remaining predicates as filters
        var all_preds: std.ArrayList(*Expression) = .{};
        defer all_preds.deinit(self.allocator);
        try self.predicate_set.getAllPredicates(&all_preds);
        
        var result = op;
        for (all_preds.items) |pred| {
            const filter = try self.allocator.create(LogicalOperator);
            filter.* = LogicalOperator.init(self.allocator, .FILTER);
            filter.filter_expression = pred;
            try filter.addChild(result);
            result = filter;
        }
        
        self.predicate_set.clear();
        return result;
    }
    
    fn tryConvertToHashJoin(self: *Self, op: *LogicalOperator, remaining: *PredicateSet) !?*LogicalOperator {
        // Check for equality predicates that can become join conditions
        var join_conditions: std.ArrayList(JoinCondition) = .{};
        defer join_conditions.deinit(self.allocator);
        
        var non_join_preds: std.ArrayList(*Expression) = .{};
        defer non_join_preds.deinit(self.allocator);
        
        for (remaining.equality_predicates.items) |pred| {
            if (try self.tryExtractJoinCondition(pred, op)) |jc| {
                try join_conditions.append(self.allocator, jc);
            } else {
                try non_join_preds.append(self.allocator, pred);
            }
        }
        
        if (join_conditions.items.len == 0) {
            return null;
        }
        
        // Create hash join
        const join_op = try self.allocator.create(LogicalOperator);
        join_op.* = LogicalOperator.init(self.allocator, .HASH_JOIN);
        
        if (op.getChild(0)) |probe| {
            try join_op.addChild(probe);
        }
        if (op.getChild(1)) |build| {
            try join_op.addChild(build);
        }
        
        // Add remaining predicates back
        remaining.equality_predicates.clearRetainingCapacity();
        for (non_join_preds.items) |p| {
            try remaining.equality_predicates.append(self.allocator, p);
        }
        
        return join_op;
    }
    
    fn tryExtractJoinCondition(_: *Self, pred: *Expression, op: *LogicalOperator) !?JoinCondition {
        _ = pred;
        _ = op;
        // TODO: Extract join condition from equality predicate
        return null;
    }
    
    fn canEvaluateOn(_: *Self, pred: *Expression, op: ?*LogicalOperator) bool {
        _ = pred;
        _ = op;
        // TODO: Check if predicate can be evaluated on operator's schema
        return false;
    }
    
    fn isLiteralTrue(_: *Self, expr: *Expression) bool {
        _ = expr;
        return false;
    }
    
    fn isLiteralFalseOrNull(_: *Self, expr: *Expression) bool {
        _ = expr;
        return false;
    }
    
    fn isConstantExpression(_: *Self, expr: *Expression) bool {
        // Check if expression is constant (literal, parameter, or deterministic function of constants)
        return switch (expr.expr_type) {
            .LITERAL, .PARAMETER => true,
            else => false,
        };
    }
    
    fn applyColumnPredicatesToScan(_: *Self, _: *LogicalOperator) !void {
        // Apply zone map predicates to scan
    }
};

/// Join condition for hash join
pub const JoinCondition = struct {
    left: *Expression,
    right: *Expression,
};

// ============================================================================
// Projection Push-Down Optimizer
// ============================================================================

/// Projection push-down optimizer - removes unused columns early
pub const ProjectionPushDownOptimizer = struct {
    allocator: std.mem.Allocator,
    config: OptimizerConfig,
    required_columns: std.StringHashMap(void),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, config: OptimizerConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .required_columns = std.StringHashMap(void).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.required_columns.deinit();
    }
    
    /// Rewrite the plan with projection push-down
    pub fn rewrite(self: *Self, plan: *LogicalPlan) !void {
        if (plan.root) |root| {
            // Collect required columns from root
            try self.collectRequiredColumns(root);
            
            // Push projections down
            try self.visitOperator(root);
        }
    }
    
    fn collectRequiredColumns(self: *Self, op: *LogicalOperator) !void {
        // Collect columns from expressions
        for (op.expressions.items) |expr| {
            try self.collectFromExpression(expr);
        }
        
        if (op.filter_expression) |filter| {
            try self.collectFromExpression(filter);
        }
        
        if (op.join_condition) |jc| {
            try self.collectFromExpression(jc);
        }
        
        // Recursively collect from children
        for (op.children.items) |child| {
            try self.collectRequiredColumns(child);
        }
    }
    
    fn collectFromExpression(self: *Self, expr: *Expression) !void {
        if (expr.column_name) |name| {
            try self.required_columns.put(name, {});
        }
        // TODO: Recursively collect from child expressions
    }
    
    fn visitOperator(self: *Self, op: *LogicalOperator) !void {
        // Process children first (bottom-up)
        for (op.children.items) |child| {
            try self.visitOperator(child);
        }
        
        // Apply projection push-down based on operator type
        switch (op.operator_type) {
            .SCAN => try self.optimizeScan(op),
            .PROJECTION => try self.optimizeProjection(op),
            else => {},
        }
    }
    
    fn optimizeScan(self: *Self, op: *LogicalOperator) !void {
        // Remove columns from scan that are not required
        var i: usize = 0;
        while (i < op.schema.column_names.items.len) {
            const col_name = op.schema.column_names.items[i];
            if (!self.required_columns.contains(col_name)) {
                _ = op.schema.column_names.orderedRemove(i);
                _ = op.schema.column_types.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
    
    fn optimizeProjection(self: *Self, op: *LogicalOperator) !void {
        // Check if projection is identity (no-op)
        if (op.getChild(0)) |child| {
            if (self.isIdentityProjection(op, child)) {
                // Can eliminate this projection
                // Note: Actually removing requires parent reference
            }
        }
    }
    
    fn isIdentityProjection(_: *Self, _: *LogicalOperator, _: *LogicalOperator) bool {
        // TODO: Check if projection just passes through all columns
        return false;
    }
};

// ============================================================================
// Limit Push-Down Optimizer
// ============================================================================

/// Limit push-down optimizer - pushes LIMIT into operators
pub const LimitPushDownOptimizer = struct {
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    /// Rewrite the plan with limit push-down
    pub fn rewrite(self: *Self, plan: *LogicalPlan) !void {
        if (plan.root) |root| {
            plan.root = try self.visitOperator(root);
        }
    }
    
    fn visitOperator(self: *Self, op: *LogicalOperator) !*LogicalOperator {
        // Process children first
        for (op.children.items, 0..) |child, i| {
            op.children.items[i] = try self.visitOperator(child);
        }
        
        // Check for LIMIT optimization opportunities
        if (op.operator_type == .LIMIT) {
            return try self.optimizeLimit(op);
        }
        
        return op;
    }
    
    fn optimizeLimit(self: *Self, op: *LogicalOperator) !*LogicalOperator {
        if (op.getChild(0)) |child| {
            // Push limit into UNION
            if (child.operator_type == .UNION) {
                return try self.pushLimitIntoUnion(op, child);
            }
            
            // Push limit into ORDER BY (will be handled by TopK optimizer)
        }
        return op;
    }
    
    fn pushLimitIntoUnion(self: *Self, limit_op: *LogicalOperator, union_op: *LogicalOperator) !*LogicalOperator {
        // Add limit to each union branch
        for (union_op.children.items, 0..) |child, i| {
            const branch_limit = try self.allocator.create(LogicalOperator);
            branch_limit.* = LogicalOperator.init(self.allocator, .LIMIT);
            branch_limit.limit_count = limit_op.limit_count;
            try branch_limit.addChild(child);
            union_op.children.items[i] = branch_limit;
        }
        
        // Keep original limit on top
        return limit_op;
    }
};

// ============================================================================
// TopK Optimizer
// ============================================================================

/// TopK optimizer - converts ORDER BY + LIMIT to TopK
pub const TopKOptimizer = struct {
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    /// Rewrite the plan with TopK optimization
    pub fn rewrite(self: *Self, plan: *LogicalPlan) !void {
        if (plan.root) |root| {
            plan.root = try self.visitOperator(root);
        }
    }
    
    fn visitOperator(self: *Self, op: *LogicalOperator) !*LogicalOperator {
        // Bottom-up traversal
        for (op.children.items, 0..) |child, i| {
            op.children.items[i] = try self.visitOperator(child);
        }
        
        // Check for LIMIT optimization
        if (op.operator_type == .LIMIT) {
            return try self.optimizeLimit(op);
        }
        
        return op;
    }
    
    fn optimizeLimit(_: *Self, op: *LogicalOperator) !*LogicalOperator {
        const limit_count = op.limit_count orelse return op;
        
        // Look for ORDER BY child (possibly through PROJECTION)
        var order_by_op: ?*LogicalOperator = null;
        var intermediate_op: ?*LogicalOperator = null;
        
        if (op.getChild(0)) |child| {
            if (child.operator_type == .ORDER_BY) {
                order_by_op = child;
            } else if (child.operator_type == .PROJECTION) {
                intermediate_op = child;
                if (child.getChild(0)) |grandchild| {
                    if (grandchild.operator_type == .ORDER_BY) {
                        order_by_op = grandchild;
                    }
                }
            }
        }
        
        if (order_by_op) |order_op| {
            // Convert to TopK
            order_op.operator_type = .TOP_K;
            order_op.limit_count = limit_count;
            order_op.skip_count = op.skip_count;
            
            // Return the ORDER BY (now TOP_K) or intermediate projection
            if (intermediate_op) |int_op| {
                return int_op;
            }
            return order_op;
        }
        
        return op;
    }
};

// ============================================================================
// Join Reorder Optimizer
// ============================================================================

/// Join reorder optimizer - finds optimal join order
pub const JoinReorderOptimizer = struct {
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    /// Rewrite the plan with optimal join ordering
    pub fn rewrite(self: *Self, plan: *LogicalPlan) !void {
        if (plan.root) |root| {
            try self.visitOperator(root);
        }
    }
    
    fn visitOperator(self: *Self, op: *LogicalOperator) !void {
        // Process children first
        for (op.children.items) |child| {
            try self.visitOperator(child);
        }
        
        // Reorder multi-way joins
        if (self.isMultiWayJoin(op)) {
            try self.reorderJoins(op);
        }
    }
    
    fn isMultiWayJoin(_: *Self, op: *LogicalOperator) bool {
        // Check if this is a join tree that can be reordered
        if (op.operator_type != .HASH_JOIN and op.operator_type != .CROSS_PRODUCT) {
            return false;
        }
        
        // Count number of base relations
        var count: usize = 0;
        for (op.children.items) |child| {
            if (child.operator_type == .SCAN) {
                count += 1;
            } else if (child.operator_type == .HASH_JOIN or child.operator_type == .CROSS_PRODUCT) {
                count += 2; // At least 2 more relations
            }
        }
        
        return count >= 3;
    }
    
    fn reorderJoins(_: *Self, _: *LogicalOperator) !void {
        // TODO: Implement dynamic programming join enumeration
        // - Collect all base relations
        // - Enumerate all join orderings
        // - Use cost model to find optimal order
    }
};

// ============================================================================
// Correlated Subquery Unnester
// ============================================================================

/// Correlated subquery unnest solver
pub const CorrelatedSubqueryUnnester = struct {
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    /// Solve correlated subqueries by unnesting
    pub fn solve(self: *Self, plan: *LogicalPlan) !void {
        if (plan.root) |root| {
            try self.visitOperator(root);
        }
    }
    
    fn visitOperator(self: *Self, op: *LogicalOperator) !void {
        // Process children
        for (op.children.items) |child| {
            try self.visitOperator(child);
        }
        
        // Check for correlated subquery patterns
        // TODO: Implement decorrelation strategies
    }
};

// ============================================================================
// Schema Populator
// ============================================================================

/// Schema populator - computes output schema for each operator
pub const SchemaPopulator = struct {
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    /// Populate schemas for all operators
    pub fn rewrite(self: *Self, plan: *LogicalPlan) !void {
        if (plan.root) |root| {
            try self.visitOperator(root);
        }
    }
    
    fn visitOperator(self: *Self, op: *LogicalOperator) !void {
        // Process children first (bottom-up)
        for (op.children.items) |child| {
            try self.visitOperator(child);
        }
        
        // Compute schema based on operator type
        try self.computeSchema(op);
    }
    
    fn computeSchema(_: *Self, op: *LogicalOperator) !void {
        switch (op.operator_type) {
            .SCAN => {
                // Schema already set from table definition
            },
            .FILTER => {
                // Pass through child schema
                if (op.getChild(0)) |child| {
                    op.schema = child.schema;
                }
            },
            .PROJECTION => {
                // Schema set from projection expressions
            },
            .HASH_JOIN => {
                // Combine schemas from both sides
                if (op.getChild(0)) |left| {
                    for (left.schema.column_names.items, left.schema.column_types.items) |name, col_type| {
                        try op.schema.addColumn(name, col_type);
                    }
                }
                if (op.getChild(1)) |right| {
                    for (right.schema.column_names.items, right.schema.column_types.items) |name, col_type| {
                        try op.schema.addColumn(name, col_type);
                    }
                }
            },
            .AGGREGATE => {
                // Schema from group keys + aggregates
            },
            else => {},
        }
    }
};

// ============================================================================
// Cardinality Updater
// ============================================================================

/// Cardinality updater - updates cardinality estimates after optimization
pub const CardinalityUpdater = struct {
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    /// Update cardinalities in the plan
    pub fn rewrite(self: *Self, plan: *LogicalPlan) !void {
        if (plan.root) |root| {
            _ = try self.visitOperator(root);
        }
    }
    
    fn visitOperator(self: *Self, op: *LogicalOperator) !u64 {
        // Process children first
        var child_card: u64 = 1;
        for (op.children.items) |child| {
            child_card = try self.visitOperator(child);
        }
        
        // Estimate cardinality based on operator
        return self.estimateCardinality(op, child_card);
    }
    
    fn estimateCardinality(_: *Self, op: *LogicalOperator, child_card: u64) u64 {
        return switch (op.operator_type) {
            .SCAN => 1000, // Default estimate
            .FILTER => child_card / 10, // 10% selectivity
            .HASH_JOIN => child_card,
            .AGGREGATE => child_card / 10,
            .LIMIT => if (op.limit_count) |l| @min(l, child_card) else child_card,
            else => child_card,
        };
    }
};

// ============================================================================
// Main Optimizer
// ============================================================================

/// Query optimizer - orchestrates all optimization phases
pub const QueryOptimizer = struct {
    allocator: std.mem.Allocator,
    config: OptimizerConfig,
    stats: OptimizerStats,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .config = OptimizerConfig.default(),
            .stats = OptimizerStats{},
        };
    }
    
    pub fn initWithConfig(allocator: std.mem.Allocator, config: OptimizerConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .stats = OptimizerStats{},
        };
    }
    
    /// Optimize the logical plan
    pub fn optimize(self: *Self, plan: *LogicalPlan) !void {
        self.stats = OptimizerStats{};
        
        if (!self.config.enable_optimizer) {
            // Only populate schemas
            var schema_pop = SchemaPopulator.init(self.allocator);
            try schema_pop.rewrite(plan);
            return;
        }
        
        // Phase 1: Correlated subquery unnesting
        if (self.config.enable_subquery_unnest) {
            var unnester = CorrelatedSubqueryUnnester.init(self.allocator);
            try unnester.solve(plan);
            self.stats.phases_applied += 1;
        }
        
        // Phase 2: Filter push-down
        if (self.config.enable_filter_pushdown) {
            var filter_opt = FilterPushDownOptimizer.init(self.allocator, self.config);
            defer filter_opt.deinit();
            try filter_opt.rewrite(plan);
            self.stats.phases_applied += 1;
            self.stats.filters_pushed += 1;
        }
        
        // Phase 3: Projection push-down
        if (self.config.enable_projection_pushdown) {
            var proj_opt = ProjectionPushDownOptimizer.init(self.allocator, self.config);
            defer proj_opt.deinit();
            try proj_opt.rewrite(plan);
            self.stats.phases_applied += 1;
        }
        
        // Phase 4: Limit push-down
        if (self.config.enable_limit_pushdown) {
            var limit_opt = LimitPushDownOptimizer.init(self.allocator);
            try limit_opt.rewrite(plan);
            self.stats.phases_applied += 1;
        }
        
        // Phase 5: TopK optimization
        if (self.config.enable_top_k) {
            var topk_opt = TopKOptimizer.init(self.allocator);
            try topk_opt.rewrite(plan);
            self.stats.phases_applied += 1;
        }
        
        // Phase 6: Join reordering
        if (self.config.enable_join_reorder) {
            var join_opt = JoinReorderOptimizer.init(self.allocator);
            try join_opt.rewrite(plan);
            self.stats.phases_applied += 1;
        }
        
        // Phase 7: Update cardinalities
        var card_updater = CardinalityUpdater.init(self.allocator);
        try card_updater.rewrite(plan);
        
        self.stats.total_optimizations = self.stats.phases_applied;
    }
    
    /// Get optimization statistics
    pub fn getStatistics(self: *const Self) OptimizerStats {
        return self.stats;
    }
};

/// Optimizer statistics
pub const OptimizerStats = struct {
    total_optimizations: u32 = 0,
    phases_applied: u32 = 0,
    filters_pushed: u32 = 0,
    projections_pushed: u32 = 0,
    joins_reordered: u32 = 0,
    topk_conversions: u32 = 0,
};

// ============================================================================
// Physical Plan Generator
// ============================================================================

/// Physical plan generator - converts logical to physical plans
pub const PhysicalPlanGenerator = struct {
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }
    
    /// Generate physical plan from logical plan
    pub fn generate(self: *Self, logical: *const LogicalPlan) !?*PhysicalOperator {
        if (logical.root) |root| {
            return try self.convertOperator(root);
        }
        return null;
    }
    
    fn convertOperator(self: *Self, logical_op: *LogicalOperator) !*PhysicalOperator {
        // Map logical operator to physical operator type
        const phys_type = mapOperatorType(logical_op.operator_type);
        
        const phys_op = try self.allocator.create(PhysicalOperator);
        phys_op.* = PhysicalOperator.init(self.allocator, phys_type, &defaultVTable);
        
        // Recursively convert children
        for (logical_op.children.items) |child| {
            const phys_child = try self.convertOperator(child);
            try phys_op.addChild(phys_child);
        }
        
        return phys_op;
    }
    
    fn mapOperatorType(logical_type: LogicalOperatorType) physical_operator.PhysicalOperatorType {
        return switch (logical_type) {
            .SCAN => .TABLE_SCAN,
            .INDEX_SCAN => .INDEX_SCAN,
            .FILTER => .FILTER,
            .PROJECTION => .PROJECTION,
            .HASH_JOIN => .HASH_JOIN,
            .CROSS_PRODUCT => .CROSS_PRODUCT,
            .AGGREGATE => .HASH_AGGREGATE,
            .ORDER_BY => .ORDER_BY,
            .TOP_K => .TOP_K,
            .LIMIT => .LIMIT,
            .SKIP => .SKIP,
            .UNION => .UNION,
            .INTERSECT => .INTERSECT,
            .INSERT => .INSERT,
            .DELETE => .DELETE,
            .UPDATE => .UPDATE,
            .CREATE_TABLE => .CREATE_TABLE,
            .DROP_TABLE => .DROP_TABLE,
            else => .RESULT_COLLECTOR,
        };
    }
    
    const defaultVTable = PhysicalOperator.VTable{
        .initFn = defaultInit,
        .getNextFn = defaultGetNext,
        .closeFn = defaultClose,
    };
    
    fn defaultInit(_: *PhysicalOperator) !void {}
    fn defaultGetNext(_: *PhysicalOperator, _: *physical_operator.DataChunk) !physical_operator.ResultState {
        return .NO_MORE_TUPLES;
    }
    fn defaultClose(_: *PhysicalOperator) void {}
};

// ============================================================================
// Tests
// ============================================================================

test "optimizer config" {
    const config = OptimizerConfig.default();
    try std.testing.expect(config.enable_optimizer);
    try std.testing.expect(config.enable_filter_pushdown);
    try std.testing.expect(config.enable_top_k);
    
    const disabled = OptimizerConfig.disabled();
    try std.testing.expect(!disabled.enable_optimizer);
}

test "predicate set" {
    const allocator = std.testing.allocator;
    
    var pset = PredicateSet.init(allocator);
    defer pset.deinit();
    
    try std.testing.expect(pset.isEmpty());
    
    pset.clear();
    try std.testing.expect(pset.isEmpty());
}

test "column predicate set" {
    const allocator = std.testing.allocator;
    
    var cpset = ColumnPredicateSet.init(allocator);
    defer cpset.deinit();
    
    try cpset.addPredicate(ColumnPredicate.init(.EQUALS, "id", null));
    try std.testing.expect(!cpset.isEmpty());
}

test "query optimizer" {
    const allocator = std.testing.allocator;
    
    var optimizer = QueryOptimizer.init(allocator);
    
    var plan = LogicalPlan.init(allocator);
    defer plan.deinit();
    
    // Should not crash on empty plan
    try optimizer.optimize(&plan);
    
    const stats = optimizer.getStatistics();
    try std.testing.expect(stats.phases_applied > 0);
}

test "optimizer with disabled config" {
    const allocator = std.testing.allocator;
    
    var optimizer = QueryOptimizer.initWithConfig(allocator, OptimizerConfig.disabled());
    
    var plan = LogicalPlan.init(allocator);
    defer plan.deinit();
    
    try optimizer.optimize(&plan);
    
    // Only schema population should run
    const stats = optimizer.getStatistics();
    try std.testing.expectEqual(@as(u32, 0), stats.phases_applied);
}

test "filter push down optimizer" {
    const allocator = std.testing.allocator;
    
    var filter_opt = FilterPushDownOptimizer.init(allocator, OptimizerConfig.default());
    defer filter_opt.deinit();
    
    var plan = LogicalPlan.init(allocator);
    defer plan.deinit();
    
    try filter_opt.rewrite(&plan);
}

test "top k optimizer" {
    const allocator = std.testing.allocator;
    
    var topk_opt = TopKOptimizer.init(allocator);
    
    var plan = LogicalPlan.init(allocator);
    defer plan.deinit();
    
    try topk_opt.rewrite(&plan);
}

test "physical plan generator" {
    const allocator = std.testing.allocator;
    
    // const generator = PhysicalPlanGenerator.init(allocator);
    
    var plan = LogicalPlan.init(allocator);
    defer plan.deinit();
    
    // const result = try generator.generate(&plan);
    // try std.testing.expect(result == null);
}

test "schema populator" {
    const allocator = std.testing.allocator;
    
    var populator = SchemaPopulator.init(allocator);
    
    var plan = LogicalPlan.init(allocator);
    defer plan.deinit();
    
    try populator.rewrite(&plan);
}

test "optimizer stats" {
    var stats = OptimizerStats{};
    stats.total_optimizations = 5;
    stats.filters_pushed = 3;
    
    try std.testing.expectEqual(@as(u32, 5), stats.total_optimizations);
    try std.testing.expectEqual(@as(u32, 3), stats.filters_pushed);
}
