//! Function Framework - Base Function and Aggregate Infrastructure
//!
//! Converted from: kuzu/src/function/function.cpp, aggregate_function.cpp
//!
//! Purpose:
//! Provides the base framework for all functions (scalar and aggregate).
//! Defines function signatures, binding, and execution interfaces.
//!
//! Architecture:
//! ```
//! Function (Base)
//!   ├── ScalarFunction        - Row-level functions (e.g., ABS, CONCAT)
//!   │   ├── ArithmeticFunc    - +, -, *, /, %
//!   │   ├── ComparisonFunc    - =, <, >, <=, >=, <>
//!   │   ├── StringFunc        - UPPER, LOWER, TRIM
//!   │   └── CastFunc          - Type conversions
//!   │
//!   └── AggregateFunction     - Multi-row aggregations
//!       ├── CountFunc         - COUNT, COUNT(*)
//!       ├── SumFunc           - SUM
//!       ├── AvgFunc           - AVG
//!       ├── MinMaxFunc        - MIN, MAX
//!       └── CollectFunc       - COLLECT (list aggregation)
//! ```

const std = @import("std");
const common = @import("common");
const evaluator = @import("evaluator");

const LogicalType = common.LogicalType;
const Value = common.Value;
const ValueVector = evaluator.ValueVector;
const SelectionVector = evaluator.SelectionVector;

/// Function type enumeration
pub const FunctionType = enum {
    SCALAR,
    AGGREGATE,
    TABLE,
    REWRITE,
};

/// Function parameter definition
pub const FunctionParameter = struct {
    name: []const u8,
    data_type: LogicalType,
    is_optional: bool,
    default_value: ?Value,
    
    pub fn init(name: []const u8, data_type: LogicalType) FunctionParameter {
        return .{
            .name = name,
            .data_type = data_type,
            .is_optional = false,
            .default_value = null,
        };
    }
    
    pub fn initOptional(name: []const u8, data_type: LogicalType, default: Value) FunctionParameter {
        return .{
            .name = name,
            .data_type = data_type,
            .is_optional = true,
            .default_value = default,
        };
    }
};

/// Function signature
pub const FunctionSignature = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    parameters: std.ArrayList(FunctionParameter),
    return_type: LogicalType,
    is_variadic: bool,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, return_type: LogicalType) Self {
        return .{
            .allocator = allocator,
            .name = name,
            .parameters = .{},
            .return_type = return_type,
            .is_variadic = false,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.parameters.deinit(self.allocator);
    }
    
    pub fn addParameter(self: *Self, param: FunctionParameter) !void {
        try self.parameters.append(self.allocator, param);
    }
    
    pub fn setVariadic(self: *Self) void {
        self.is_variadic = true;
    }
    
    pub fn matches(self: *const Self, arg_types: []const LogicalType) bool {
        if (self.is_variadic) {
            if (arg_types.len < self.parameters.items.len) return false;
            // Check required parameters
            for (self.parameters.items, 0..) |param, i| {
                if (!param.is_optional and !typeMatches(param.data_type, arg_types[i])) {
                    return false;
                }
            }
            return true;
        }
        
        if (arg_types.len != self.parameters.items.len) {
            // Check if remaining are optional
            if (arg_types.len > self.parameters.items.len) return false;
            for (self.parameters.items[arg_types.len..]) |param| {
                if (!param.is_optional) return false;
            }
        }
        
        for (arg_types, 0..) |arg_type, i| {
            if (i >= self.parameters.items.len) break;
            if (!typeMatches(self.parameters.items[i].data_type, arg_type)) {
                return false;
            }
        }
        return true;
    }
    
    fn typeMatches(expected: LogicalType, actual: LogicalType) bool {
        if (expected.type_id == .ANY) return true;
        return expected.type_id == actual.type_id;
    }
};

/// Scalar function execution function pointer
pub const ScalarExecFunc = *const fn (
    inputs: []*ValueVector,
    output: *ValueVector,
    sel_vector: ?*SelectionVector,
) anyerror!void;

/// Scalar function select function pointer
pub const ScalarSelectFunc = *const fn (
    inputs: []*ValueVector,
    sel_vector: *SelectionVector,
) bool;

/// Scalar Function
pub const ScalarFunction = struct {
    allocator: std.mem.Allocator,
    signature: FunctionSignature,
    exec_func: ?ScalarExecFunc,
    select_func: ?ScalarSelectFunc,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, return_type: LogicalType) Self {
        return .{
            .allocator = allocator,
            .signature = FunctionSignature.init(allocator, name, return_type),
            .exec_func = null,
            .select_func = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.signature.deinit();
    }
    
    pub fn setExecFunc(self: *Self, func: ScalarExecFunc) void {
        self.exec_func = func;
    }
    
    pub fn setSelectFunc(self: *Self, func: ScalarSelectFunc) void {
        self.select_func = func;
    }
    
    pub fn execute(self: *Self, inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
        if (self.exec_func) |func| {
            try func(inputs, output, sel_vector);
        }
    }
    
    pub fn select(self: *Self, inputs: []*ValueVector, sel_vector: *SelectionVector) bool {
        if (self.select_func) |func| {
            return func(inputs, sel_vector);
        }
        return true;
    }
};

/// Aggregate state - opaque state for aggregate functions
pub const AggregateState = struct {
    data: [64]u8 align(8), // Fixed-size state buffer (aligned for typed access)
    is_initialized: bool,
    is_null: bool,
    
    pub fn init() AggregateState {
        return .{
            .data = [_]u8{0} ** 64,
            .is_initialized = false,
            .is_null = true,
        };
    }
    
    pub fn getTypedState(self: *AggregateState, comptime T: type) *T {
        return @ptrCast(@alignCast(&self.data));
    }
    
    pub fn reset(self: *AggregateState) void {
        @memset(&self.data, 0);
        self.is_initialized = false;
        self.is_null = true;
    }
};

/// Aggregate function callbacks
pub const AggregateInitFunc = *const fn (state: *AggregateState) void;
pub const AggregateUpdateFunc = *const fn (state: *AggregateState, input: *ValueVector, multiplicity: u64) void;
pub const AggregateUpdatePosFunc = *const fn (state: *AggregateState, input: *ValueVector, pos: u64, multiplicity: u64) void;
pub const AggregateCombineFunc = *const fn (state: *AggregateState, other: *AggregateState) void;
pub const AggregateFinalizeFunc = *const fn (state: *AggregateState, output: *ValueVector, pos: u64) void;

/// Aggregate Function
pub const AggregateFunction = struct {
    allocator: std.mem.Allocator,
    signature: FunctionSignature,
    
    /// Whether the aggregate needs to handle nulls explicitly
    needs_to_handle_nulls: bool,
    
    /// Whether this is a DISTINCT aggregate
    is_distinct: bool,
    
    /// Callback functions
    init_func: ?AggregateInitFunc,
    update_all_func: ?AggregateUpdateFunc,
    update_pos_func: ?AggregateUpdatePosFunc,
    combine_func: ?AggregateCombineFunc,
    finalize_func: ?AggregateFinalizeFunc,
    
    /// Initial null state for reference
    initial_null_state: AggregateState,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, return_type: LogicalType) Self {
        return .{
            .allocator = allocator,
            .signature = FunctionSignature.init(allocator, name, return_type),
            .needs_to_handle_nulls = false,
            .is_distinct = false,
            .init_func = null,
            .update_all_func = null,
            .update_pos_func = null,
            .combine_func = null,
            .finalize_func = null,
            .initial_null_state = AggregateState.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.signature.deinit();
    }
    
    pub fn setDistinct(self: *Self, distinct: bool) void {
        self.is_distinct = distinct;
    }
    
    pub fn setNeedsToHandleNulls(self: *Self, needs: bool) void {
        self.needs_to_handle_nulls = needs;
    }
    
    /// Initialize a new aggregate state
    pub fn initializeState(self: *Self, state: *AggregateState) void {
        if (self.init_func) |func| {
            func(state);
        }
    }
    
    /// Update state with all values in vector
    pub fn updateAll(self: *Self, state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
        if (self.update_all_func) |func| {
            func(state, input, multiplicity);
        }
    }
    
    /// Update state with single position
    pub fn updatePos(self: *Self, state: *AggregateState, input: *ValueVector, pos: u64, multiplicity: u64) void {
        if (self.update_pos_func) |func| {
            func(state, input, pos, multiplicity);
        }
    }
    
    /// Combine two states (for parallel aggregation)
    pub fn combine(self: *Self, state: *AggregateState, other: *AggregateState) void {
        if (self.combine_func) |func| {
            func(state, other);
        }
    }
    
    /// Finalize and write result
    pub fn finalize(self: *Self, state: *AggregateState, output: *ValueVector, pos: u64) void {
        if (self.finalize_func) |func| {
            func(state, output, pos);
        }
    }
    
    /// Create initial null state
    pub fn createInitialNullState(self: *Self) AggregateState {
        var state = AggregateState.init();
        self.initializeState(&state);
        return state;
    }
};

/// Function catalog - registry of all functions
pub const FunctionCatalog = struct {
    allocator: std.mem.Allocator,
    scalar_functions: std.StringHashMap(std.ArrayList(ScalarFunction)),
    aggregate_functions: std.StringHashMap(std.ArrayList(AggregateFunction)),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .scalar_functions = .{},
            .aggregate_functions = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        var scalar_iter = self.scalar_functions.valueIterator();
        while (scalar_iter.next()) |funcs| {
            for (funcs.items) |*func| {
                func.deinit();
            }
            funcs.deinit();
        }
        self.scalar_functions.deinit(self.allocator);
        
        var agg_iter = self.aggregate_functions.valueIterator();
        while (agg_iter.next()) |funcs| {
            for (funcs.items) |*func| {
                func.deinit();
            }
            funcs.deinit();
        }
        self.aggregate_functions.deinit(self.allocator);
    }
    
    pub fn registerScalar(self: *Self, func: ScalarFunction) !void {
        const name = func.signature.name;
        if (self.scalar_functions.getPtr(name)) |list| {
            try list.append(self.allocator, func);
        } else {
            var list = .{};
            try list.append(self.allocator, func);
            try self.scalar_functions.put(name, list);
        }
    }
    
    pub fn registerAggregate(self: *Self, func: AggregateFunction) !void {
        const name = func.signature.name;
        if (self.aggregate_functions.getPtr(name)) |list| {
            try list.append(self.allocator, func);
        } else {
            var list = .{};
            try list.append(self.allocator, func);
            try self.aggregate_functions.put(name, list);
        }
    }
    
    pub fn getScalar(self: *Self, name: []const u8, arg_types: []const LogicalType) ?*ScalarFunction {
        if (self.scalar_functions.getPtr(name)) |funcs| {
            for (funcs.items) |*func| {
                if (func.signature.matches(arg_types)) {
                    return func;
                }
            }
        }
        return null;
    }
    
    pub fn getAggregate(self: *Self, name: []const u8, arg_types: []const LogicalType) ?*AggregateFunction {
        if (self.aggregate_functions.getPtr(name)) |funcs| {
            for (funcs.items) |*func| {
                if (func.signature.matches(arg_types)) {
                    return func;
                }
            }
        }
        return null;
    }
};

/// Built-in function registry - creates all built-in functions
pub const BuiltInFunctions = struct {
    /// Register all built-in functions
    pub fn registerAll(catalog: *FunctionCatalog) !void {
        try registerArithmeticFunctions(catalog);
        try registerComparisonFunctions(catalog);
        try registerAggregateFunctions(catalog);
    }
    
    fn registerArithmeticFunctions(catalog: *FunctionCatalog) !void {
        // These are now handled by Mangle functions.mg
        // We keep stubs for direct Zig usage
        _ = catalog;
    }
    
    fn registerComparisonFunctions(catalog: *FunctionCatalog) !void {
        // Comparison functions - integrated with Mangle rules.mg
        _ = catalog;
    }
    
    fn registerAggregateFunctions(catalog: *FunctionCatalog) !void {
        // Import aggregate modules
        const count_mod = @import("aggregate/count.zig");
        const sum_mod = @import("aggregate/sum.zig");
        const avg_mod = @import("aggregate/avg.zig");
        const min_max_mod = @import("aggregate/min_max.zig");
        
        try count_mod.registerFunctions(catalog);
        try sum_mod.registerFunctions(catalog);
        try avg_mod.registerFunctions(catalog);
        try min_max_mod.registerFunctions(catalog);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "function signature" {
    const allocator = std.testing.allocator;
    
    var sig = FunctionSignature.init(allocator, "TEST", .INT64);
    defer sig.deinit();
    
    try sig.addParameter(FunctionParameter.init("a", .INT64));
    try sig.addParameter(FunctionParameter.init("b", .INT64));
    
    const matching_types = [_]LogicalType{ .INT64, .INT64 };
    try std.testing.expect(sig.matches(&matching_types));
    
    const wrong_types = [_]LogicalType{ .STRING, .INT64 };
    try std.testing.expect(!sig.matches(&wrong_types));
    
    const wrong_count = [_]LogicalType{.INT64};
    try std.testing.expect(!sig.matches(&wrong_count));
}

test "aggregate state" {
    var state = AggregateState.init();
    
    try std.testing.expect(!state.is_initialized);
    try std.testing.expect(state.is_null);
    
    // Use typed state
    const CountState = struct {
        count: i64,
    };
    
    const typed = state.getTypedState(CountState);
    typed.count = 42;
    
    try std.testing.expectEqual(@as(i64, 42), typed.count);
    
    state.reset();
    try std.testing.expectEqual(@as(i64, 0), typed.count);
}

test "scalar function" {
    const allocator = std.testing.allocator;
    
    var func = ScalarFunction.init(allocator, "ABS", .INT64);
    defer func.deinit();
    
    try func.signature.addParameter(FunctionParameter.init("input", .INT64));
    
    try std.testing.expectEqualStrings("ABS", func.signature.name);
    try std.testing.expectEqual(LogicalType.INT64, func.signature.return_type);
}

test "aggregate function" {
    const allocator = std.testing.allocator;
    
    var func = AggregateFunction.init(allocator, "COUNT", .INT64);
    defer func.deinit();
    
    func.setDistinct(true);
    try std.testing.expect(func.is_distinct);
    
    func.setNeedsToHandleNulls(true);
    try std.testing.expect(func.needs_to_handle_nulls);
}