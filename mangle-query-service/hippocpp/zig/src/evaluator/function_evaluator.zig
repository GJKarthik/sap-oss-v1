//! Function Evaluator - Scalar Function Execution
//!
//! Converted from: kuzu/src/expression_evaluator/function_evaluator.cpp
//!
//! Purpose:
//! Evaluates scalar function calls during query execution. Resolves
//! function bindings, evaluates arguments, and invokes the function.

const std = @import("std");
const common = @import("../common/common.zig");
const evaluator_mod = @import("evaluator.zig");
const function_mod = @import("../function/function.zig");

const LogicalType = common.LogicalType;
const Value = common.Value;
const ValueVector = evaluator_mod.ValueVector;
const SelectionVector = evaluator_mod.SelectionVector;
const ResultSet = evaluator_mod.ResultSet;
const ExpressionEvaluator = evaluator_mod.ExpressionEvaluator;
const ExpressionType = evaluator_mod.ExpressionType;
const DataChunkState = evaluator_mod.DataChunkState;
const ScalarFunction = function_mod.ScalarFunction;
const FunctionCatalog = function_mod.FunctionCatalog;

/// Function evaluator - evaluates scalar function calls
pub const FunctionEvaluator = struct {
    base: ExpressionEvaluator,
    
    /// The bound function
    func: ?*ScalarFunction,
    
    /// Function name (for lookup)
    function_name: []const u8,
    
    /// Argument evaluators
    arg_evaluators: std.ArrayList(*ExpressionEvaluator),
    
    /// Argument vectors (resolved from evaluators)
    arg_vectors: std.ArrayList(*ValueVector),
    
    const Self = @This();
    
    pub fn create(allocator: std.mem.Allocator, function_name: []const u8, return_type: LogicalType) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .base = ExpressionEvaluator.init(
                allocator,
                .FUNCTION,
                return_type,
                function_name,
                &function_vtable,
            ),
            .func = null,
            .function_name = function_name,
            .arg_evaluators = std.ArrayList(*ExpressionEvaluator).init(allocator),
            .arg_vectors = std.ArrayList(*ValueVector).init(allocator),
        };
        return self;
    }
    
    /// Add argument evaluator
    pub fn addArgument(self: *Self, arg: *ExpressionEvaluator) !void {
        try self.arg_evaluators.append(arg);
    }
    
    /// Bind to a function from catalog
    pub fn bindFunction(self: *Self, catalog: *FunctionCatalog) !void {
        // Collect argument types
        var arg_types = std.ArrayList(LogicalType).init(self.base.allocator);
        defer arg_types.deinit();
        
        for (self.arg_evaluators.items) |arg_eval| {
            try arg_types.append(arg_eval.return_type);
        }
        
        // Look up function
        self.func = catalog.getScalar(self.function_name, arg_types.items);
    }
    
    fn evaluateImpl(base: *ExpressionEvaluator) !void {
        const self: *Self = @fieldParentPtr("base", base);
        
        // Evaluate all arguments first
        for (self.arg_evaluators.items) |arg_eval| {
            try arg_eval.evaluate();
        }
        
        // Collect argument vectors
        self.arg_vectors.clearRetainingCapacity();
        for (self.arg_evaluators.items) |arg_eval| {
            if (arg_eval.result_vector) |rv| {
                try self.arg_vectors.append(rv);
            }
        }
        
        // Execute function
        if (self.func) |func| {
            if (base.result_vector) |output| {
                try func.execute(self.arg_vectors.items, output, null);
            }
        }
    }
    
    fn evaluateWithCountImpl(base: *ExpressionEvaluator, count: u64) !void {
        _ = count;
        try evaluateImpl(base);
    }
    
    fn selectInternalImpl(base: *ExpressionEvaluator, sel_vector: *SelectionVector) bool {
        const self: *Self = @fieldParentPtr("base", base);
        
        // Evaluate arguments
        for (self.arg_evaluators.items) |arg_eval| {
            arg_eval.evaluate() catch return false;
        }
        
        // Collect vectors
        self.arg_vectors.clearRetainingCapacity();
        for (self.arg_evaluators.items) |arg_eval| {
            if (arg_eval.result_vector) |rv| {
                self.arg_vectors.append(rv) catch return false;
            }
        }
        
        // Use function's select method
        if (self.func) |func| {
            return func.select(self.arg_vectors.items, sel_vector);
        }
        
        return true;
    }
    
    fn resolveResultVectorImpl(base: *ExpressionEvaluator, result_set: *ResultSet) !void {
        const self: *Self = @fieldParentPtr("base", base);
        
        // Resolve argument vectors first
        for (self.arg_evaluators.items) |arg_eval| {
            try arg_eval.vtable.resolve_result_vector(arg_eval, result_set);
        }
        
        // Create result vector
        const rv = try base.allocator.create(ValueVector);
        rv.* = try ValueVector.init(base.allocator, base.return_type, 2048);
        base.result_vector = rv;
        
        // Resolve result state from children
        base.resolveResultStateFromChildren();
    }
    
    fn cloneImpl(base: *ExpressionEvaluator) !*ExpressionEvaluator {
        const self: *Self = @fieldParentPtr("base", base);
        const new = try Self.create(base.allocator, self.function_name, base.return_type);
        new.func = self.func;
        
        // Clone arguments
        for (self.arg_evaluators.items) |arg_eval| {
            const cloned_arg = try arg_eval.clone();
            try new.addArgument(cloned_arg);
        }
        
        return &new.base;
    }
    
    fn destroyImpl(base: *ExpressionEvaluator) void {
        const self: *Self = @fieldParentPtr("base", base);
        
        // Destroy argument evaluators
        for (self.arg_evaluators.items) |arg_eval| {
            arg_eval.destroy();
        }
        self.arg_evaluators.deinit();
        self.arg_vectors.deinit();
        
        if (base.result_vector) |rv| {
            rv.deinit();
            base.allocator.destroy(rv);
        }
        base.deinit();
        base.allocator.destroy(self);
    }
};

const function_vtable = ExpressionEvaluator.VTable{
    .evaluate = FunctionEvaluator.evaluateImpl,
    .evaluate_with_count = FunctionEvaluator.evaluateWithCountImpl,
    .select_internal = FunctionEvaluator.selectInternalImpl,
    .resolve_result_vector = FunctionEvaluator.resolveResultVectorImpl,
    .clone = FunctionEvaluator.cloneImpl,
    .destroy = FunctionEvaluator.destroyImpl,
};

/// Aggregate evaluator - evaluates aggregate function calls
pub const AggregateEvaluator = struct {
    base: ExpressionEvaluator,
    
    /// The bound aggregate function
    agg_func: ?*function_mod.AggregateFunction,
    
    /// Function name
    function_name: []const u8,
    
    /// Argument evaluator (aggregates have 1 argument)
    arg_evaluator: ?*ExpressionEvaluator,
    
    /// Aggregate state
    state: function_mod.AggregateState,
    
    const Self = @This();
    
    pub fn create(allocator: std.mem.Allocator, function_name: []const u8, return_type: LogicalType) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .base = ExpressionEvaluator.init(
                allocator,
                .AGGREGATE,
                return_type,
                function_name,
                &aggregate_vtable,
            ),
            .agg_func = null,
            .function_name = function_name,
            .arg_evaluator = null,
            .state = function_mod.AggregateState.init(),
        };
        return self;
    }
    
    /// Set argument evaluator
    pub fn setArgument(self: *Self, arg: *ExpressionEvaluator) void {
        self.arg_evaluator = arg;
    }
    
    /// Bind to aggregate function from catalog
    pub fn bindFunction(self: *Self, catalog: *FunctionCatalog) !void {
        if (self.arg_evaluator) |arg| {
            const arg_types = [_]LogicalType{arg.return_type};
            self.agg_func = catalog.getAggregate(self.function_name, &arg_types);
        } else {
            // COUNT(*) case - no arguments
            const arg_types = [_]LogicalType{};
            self.agg_func = catalog.getAggregate(self.function_name, &arg_types);
        }
        
        // Initialize state
        if (self.agg_func) |func| {
            func.initializeState(&self.state);
        }
    }
    
    /// Initialize state
    pub fn initState(self: *Self) void {
        if (self.agg_func) |func| {
            func.initializeState(&self.state);
        }
    }
    
    /// Update state with input
    pub fn update(self: *Self, multiplicity: u64) !void {
        if (self.arg_evaluator) |arg| {
            try arg.evaluate();
            if (arg.result_vector) |input| {
                if (self.agg_func) |func| {
                    func.updateAll(&self.state, input, multiplicity);
                }
            }
        }
    }
    
    /// Combine with another state
    pub fn combine(self: *Self, other: *Self) void {
        if (self.agg_func) |func| {
            func.combine(&self.state, &other.state);
        }
    }
    
    /// Finalize and get result
    pub fn finalize(self: *Self, output: *ValueVector, pos: u64) void {
        if (self.agg_func) |func| {
            func.finalize(&self.state, output, pos);
        }
    }
    
    fn evaluateImpl(base: *ExpressionEvaluator) !void {
        const self: *Self = @fieldParentPtr("base", base);
        
        // Finalize aggregate to result vector
        if (base.result_vector) |output| {
            self.finalize(output, 0);
        }
    }
    
    fn evaluateWithCountImpl(base: *ExpressionEvaluator, count: u64) !void {
        const self: *Self = @fieldParentPtr("base", base);
        try self.update(count);
    }
    
    fn selectInternalImpl(base: *ExpressionEvaluator, sel_vector: *SelectionVector) bool {
        _ = base;
        _ = sel_vector;
        // Aggregates don't filter rows
        return true;
    }
    
    fn resolveResultVectorImpl(base: *ExpressionEvaluator, result_set: *ResultSet) !void {
        const self: *Self = @fieldParentPtr("base", base);
        
        // Resolve argument vector
        if (self.arg_evaluator) |arg| {
            try arg.vtable.resolve_result_vector(arg, result_set);
        }
        
        // Create result vector (single value for aggregate)
        const rv = try base.allocator.create(ValueVector);
        rv.* = try ValueVector.init(base.allocator, base.return_type, 1);
        base.result_vector = rv;
        base.is_result_flat = true;
    }
    
    fn cloneImpl(base: *ExpressionEvaluator) !*ExpressionEvaluator {
        const self: *Self = @fieldParentPtr("base", base);
        const new = try Self.create(base.allocator, self.function_name, base.return_type);
        new.agg_func = self.agg_func;
        
        if (self.arg_evaluator) |arg| {
            new.arg_evaluator = try arg.clone();
        }
        
        return &new.base;
    }
    
    fn destroyImpl(base: *ExpressionEvaluator) void {
        const self: *Self = @fieldParentPtr("base", base);
        
        if (self.arg_evaluator) |arg| {
            arg.destroy();
        }
        
        if (base.result_vector) |rv| {
            rv.deinit();
            base.allocator.destroy(rv);
        }
        base.deinit();
        base.allocator.destroy(self);
    }
};

const aggregate_vtable = ExpressionEvaluator.VTable{
    .evaluate = AggregateEvaluator.evaluateImpl,
    .evaluate_with_count = AggregateEvaluator.evaluateWithCountImpl,
    .select_internal = AggregateEvaluator.selectInternalImpl,
    .resolve_result_vector = AggregateEvaluator.resolveResultVectorImpl,
    .clone = AggregateEvaluator.cloneImpl,
    .destroy = AggregateEvaluator.destroyImpl,
};

// ============================================================================
// Tests
// ============================================================================

test "function evaluator creation" {
    const allocator = std.testing.allocator;
    
    const func_eval = try FunctionEvaluator.create(allocator, "ABS", .INT64);
    defer func_eval.base.destroy();
    
    try std.testing.expectEqual(ExpressionType.FUNCTION, func_eval.base.expression_type);
    try std.testing.expectEqual(LogicalType.INT64, func_eval.base.return_type);
    try std.testing.expectEqualStrings("ABS", func_eval.function_name);
}

test "aggregate evaluator creation" {
    const allocator = std.testing.allocator;
    
    const agg_eval = try AggregateEvaluator.create(allocator, "COUNT", .INT64);
    defer agg_eval.base.destroy();
    
    try std.testing.expectEqual(ExpressionType.AGGREGATE, agg_eval.base.expression_type);
    try std.testing.expectEqual(LogicalType.INT64, agg_eval.base.return_type);
    try std.testing.expectEqualStrings("COUNT", agg_eval.function_name);
}

test "aggregate state initialization" {
    const allocator = std.testing.allocator;
    
    const agg_eval = try AggregateEvaluator.create(allocator, "SUM", .INT64);
    defer agg_eval.base.destroy();
    
    // State should be uninitialized until bindFunction
    try std.testing.expect(!agg_eval.state.is_initialized);
}