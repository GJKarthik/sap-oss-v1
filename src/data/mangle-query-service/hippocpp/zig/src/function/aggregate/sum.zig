//! SUM Aggregate Function
//!
//! Converted from: kuzu/src/function/aggregate/sum.cpp
//!
//! Purpose:
//! Implements the SUM aggregate function which sums numeric values.
//! Handles integer overflow by using INT128 for integer inputs.
//!
//! Mangle Integration:
//! The sum semantics are also defined in aggregations.mg:
//!   sum(X) :- ... aggregate ...

const std = @import("std");
const common = @import("../../common/common.zig");
const evaluator = @import("../../evaluator/evaluator.zig");
const function = @import("../function.zig");

const LogicalType = common.LogicalType;
const ValueVector = evaluator.ValueVector;
const AggregateState = function.AggregateState;
const AggregateFunction = function.AggregateFunction;
const FunctionParameter = function.FunctionParameter;
const FunctionCatalog = function.FunctionCatalog;

/// SUM state for integer types (uses i128 to avoid overflow)
pub const SumStateInt = struct {
    sum: i128,
    has_value: bool,
    
    pub fn init() SumStateInt {
        return .{
            .sum = 0,
            .has_value = false,
        };
    }
};

/// SUM state for floating point types
pub const SumStateFloat = struct {
    sum: f64,
    has_value: bool,
    
    pub fn init() SumStateFloat {
        return .{
            .sum = 0.0,
            .has_value = false,
        };
    }
};

/// Initialize SUM state for integers
fn initializeSumInt(state: *AggregateState) void {
    const typed = state.getTypedState(SumStateInt);
    typed.* = SumStateInt.init();
    state.is_initialized = true;
    state.is_null = true; // SUM of no values is NULL
}

/// Initialize SUM state for floats
fn initializeSumFloat(state: *AggregateState) void {
    const typed = state.getTypedState(SumStateFloat);
    typed.* = SumStateFloat.init();
    state.is_initialized = true;
    state.is_null = true;
}

/// Update SUM(INT64) with all values
fn updateAllSumInt64(state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
    const typed = state.getTypedState(SumStateInt);
    
    const size = if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |i| {
        if (!input.isNull(i)) {
            if (input.getValue(i64, i)) |value| {
                typed.sum += @as(i128, value) * @as(i128, @intCast(multiplicity));
                typed.has_value = true;
                state.is_null = false;
            }
        }
    }
}

/// Update SUM(INT32) with all values
fn updateAllSumInt32(state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
    const typed = state.getTypedState(SumStateInt);
    
    const size = if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |i| {
        if (!input.isNull(i)) {
            if (input.getValue(i32, i)) |value| {
                typed.sum += @as(i128, value) * @as(i128, @intCast(multiplicity));
                typed.has_value = true;
                state.is_null = false;
            }
        }
    }
}

/// Update SUM(DOUBLE) with all values
fn updateAllSumDouble(state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
    const typed = state.getTypedState(SumStateFloat);
    
    const size = if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |i| {
        if (!input.isNull(i)) {
            if (input.getValue(f64, i)) |value| {
                typed.sum += value * @as(f64, @floatFromInt(multiplicity));
                typed.has_value = true;
                state.is_null = false;
            }
        }
    }
}

/// Update SUM(FLOAT) with all values  
fn updateAllSumFloat(state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
    const typed = state.getTypedState(SumStateFloat);
    
    const size = if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |i| {
        if (!input.isNull(i)) {
            if (input.getValue(f32, i)) |value| {
                typed.sum += @as(f64, value) * @as(f64, @floatFromInt(multiplicity));
                typed.has_value = true;
                state.is_null = false;
            }
        }
    }
}

/// Update SUM(INT64) at specific position
fn updatePosSumInt64(state: *AggregateState, input: *ValueVector, pos: u64, multiplicity: u64) void {
    const typed = state.getTypedState(SumStateInt);
    
    if (!input.isNull(pos)) {
        if (input.getValue(i64, pos)) |value| {
            typed.sum += @as(i128, value) * @as(i128, @intCast(multiplicity));
            typed.has_value = true;
            state.is_null = false;
        }
    }
}

/// Update SUM(DOUBLE) at specific position
fn updatePosSumDouble(state: *AggregateState, input: *ValueVector, pos: u64, multiplicity: u64) void {
    const typed = state.getTypedState(SumStateFloat);
    
    if (!input.isNull(pos)) {
        if (input.getValue(f64, pos)) |value| {
            typed.sum += value * @as(f64, @floatFromInt(multiplicity));
            typed.has_value = true;
            state.is_null = false;
        }
    }
}

/// Combine two SUM integer states
fn combineSumInt(state: *AggregateState, other: *AggregateState) void {
    const typed = state.getTypedState(SumStateInt);
    const other_typed = other.getTypedState(SumStateInt);
    
    if (other_typed.has_value) {
        typed.sum += other_typed.sum;
        typed.has_value = true;
        state.is_null = false;
    }
}

/// Combine two SUM float states
fn combineSumFloat(state: *AggregateState, other: *AggregateState) void {
    const typed = state.getTypedState(SumStateFloat);
    const other_typed = other.getTypedState(SumStateFloat);
    
    if (other_typed.has_value) {
        typed.sum += other_typed.sum;
        typed.has_value = true;
        state.is_null = false;
    }
}

/// Finalize SUM(INT) and write as INT128
fn finalizeSumInt128(state: *AggregateState, output: *ValueVector, pos: u64) void {
    const typed = state.getTypedState(SumStateInt);
    
    if (!typed.has_value) {
        output.setNull(pos, true);
    } else {
        // Write as i128
        output.setValue(i128, pos, typed.sum);
    }
}

/// Finalize SUM(INT) and write as INT64 (with potential truncation)
fn finalizeSumInt64(state: *AggregateState, output: *ValueVector, pos: u64) void {
    const typed = state.getTypedState(SumStateInt);
    
    if (!typed.has_value) {
        output.setNull(pos, true);
    } else {
        // Truncate to i64 (may overflow for very large sums)
        output.setValue(i64, pos, @truncate(typed.sum));
    }
}

/// Finalize SUM(DOUBLE) and write result
fn finalizeSumDouble(state: *AggregateState, output: *ValueVector, pos: u64) void {
    const typed = state.getTypedState(SumStateFloat);
    
    if (!typed.has_value) {
        output.setNull(pos, true);
    } else {
        output.setValue(f64, pos, typed.sum);
    }
}

/// Register SUM functions with catalog
pub fn registerFunctions(catalog: *FunctionCatalog) !void {
    // SUM(INT8) -> INT128
    {
        var func = AggregateFunction.init(catalog.allocator, "SUM", .INT128);
        try func.signature.addParameter(FunctionParameter.init("input", .INT8));
        func.init_func = initializeSumInt;
        func.update_all_func = updateAllSumInt32;
        func.combine_func = combineSumInt;
        func.finalize_func = finalizeSumInt128;
        try catalog.registerAggregate(func);
    }
    
    // SUM(INT16) -> INT128
    {
        var func = AggregateFunction.init(catalog.allocator, "SUM", .INT128);
        try func.signature.addParameter(FunctionParameter.init("input", .INT16));
        func.init_func = initializeSumInt;
        func.update_all_func = updateAllSumInt32;
        func.combine_func = combineSumInt;
        func.finalize_func = finalizeSumInt128;
        try catalog.registerAggregate(func);
    }
    
    // SUM(INT32) -> INT128
    {
        var func = AggregateFunction.init(catalog.allocator, "SUM", .INT128);
        try func.signature.addParameter(FunctionParameter.init("input", .INT32));
        func.init_func = initializeSumInt;
        func.update_all_func = updateAllSumInt32;
        func.combine_func = combineSumInt;
        func.finalize_func = finalizeSumInt128;
        try catalog.registerAggregate(func);
    }
    
    // SUM(INT64) -> INT128
    {
        var func = AggregateFunction.init(catalog.allocator, "SUM", .INT128);
        try func.signature.addParameter(FunctionParameter.init("input", .INT64));
        func.init_func = initializeSumInt;
        func.update_all_func = updateAllSumInt64;
        func.update_pos_func = updatePosSumInt64;
        func.combine_func = combineSumInt;
        func.finalize_func = finalizeSumInt128;
        try catalog.registerAggregate(func);
    }
    
    // SUM(FLOAT) -> DOUBLE
    {
        var func = AggregateFunction.init(catalog.allocator, "SUM", .DOUBLE);
        try func.signature.addParameter(FunctionParameter.init("input", .FLOAT));
        func.init_func = initializeSumFloat;
        func.update_all_func = updateAllSumFloat;
        func.combine_func = combineSumFloat;
        func.finalize_func = finalizeSumDouble;
        try catalog.registerAggregate(func);
    }
    
    // SUM(DOUBLE) -> DOUBLE
    {
        var func = AggregateFunction.init(catalog.allocator, "SUM", .DOUBLE);
        try func.signature.addParameter(FunctionParameter.init("input", .DOUBLE));
        func.init_func = initializeSumFloat;
        func.update_all_func = updateAllSumDouble;
        func.update_pos_func = updatePosSumDouble;
        func.combine_func = combineSumFloat;
        func.finalize_func = finalizeSumDouble;
        try catalog.registerAggregate(func);
    }
}

/// Create a standalone SUM function for integers
pub fn createSumIntFunction(allocator: std.mem.Allocator, input_type: LogicalType) !AggregateFunction {
    var func = AggregateFunction.init(allocator, "SUM", .INT128);
    try func.signature.addParameter(FunctionParameter.init("input", input_type));
    func.init_func = initializeSumInt;
    func.update_all_func = updateAllSumInt64;
    func.update_pos_func = updatePosSumInt64;
    func.combine_func = combineSumInt;
    func.finalize_func = finalizeSumInt128;
    return func;
}

/// Create a standalone SUM function for floats
pub fn createSumFloatFunction(allocator: std.mem.Allocator, input_type: LogicalType) !AggregateFunction {
    var func = AggregateFunction.init(allocator, "SUM", .DOUBLE);
    try func.signature.addParameter(FunctionParameter.init("input", input_type));
    func.init_func = initializeSumFloat;
    func.update_all_func = updateAllSumDouble;
    func.update_pos_func = updatePosSumDouble;
    func.combine_func = combineSumFloat;
    func.finalize_func = finalizeSumDouble;
    return func;
}

// ============================================================================
// Tests
// ============================================================================

test "sum int state" {
    var state = AggregateState.init();
    initializeSumInt(&state);
    
    try std.testing.expect(state.is_initialized);
    try std.testing.expect(state.is_null);
    
    const typed = state.getTypedState(SumStateInt);
    try std.testing.expectEqual(@as(i128, 0), typed.sum);
    try std.testing.expect(!typed.has_value);
}

test "sum float state" {
    var state = AggregateState.init();
    initializeSumFloat(&state);
    
    try std.testing.expect(state.is_initialized);
    try std.testing.expect(state.is_null);
    
    const typed = state.getTypedState(SumStateFloat);
    try std.testing.expectEqual(@as(f64, 0.0), typed.sum);
    try std.testing.expect(!typed.has_value);
}

test "sum int64 update" {
    const allocator = std.testing.allocator;
    
    var state = AggregateState.init();
    initializeSumInt(&state);
    
    var input = try ValueVector.init(allocator, .INT64, 5);
    defer input.deinit();
    
    input.setValue(i64, 0, 10);
    input.setValue(i64, 1, 20);
    input.setValue(i64, 2, 30);
    input.setNull(3, true);
    input.setValue(i64, 4, 40);
    
    updateAllSumInt64(&state, &input, 1);
    
    const typed = state.getTypedState(SumStateInt);
    try std.testing.expectEqual(@as(i128, 100), typed.sum);
    try std.testing.expect(typed.has_value);
}

test "sum double update" {
    const allocator = std.testing.allocator;
    
    var state = AggregateState.init();
    initializeSumFloat(&state);
    
    var input = try ValueVector.init(allocator, .DOUBLE, 3);
    defer input.deinit();
    
    input.setValue(f64, 0, 1.5);
    input.setValue(f64, 1, 2.5);
    input.setValue(f64, 2, 3.0);
    
    updateAllSumDouble(&state, &input, 1);
    
    const typed = state.getTypedState(SumStateFloat);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), typed.sum, 0.001);
    try std.testing.expect(typed.has_value);
}

test "sum combine" {
    var state1 = AggregateState.init();
    initializeSumInt(&state1);
    var typed1 = state1.getTypedState(SumStateInt);
    typed1.sum = 100;
    typed1.has_value = true;
    
    var state2 = AggregateState.init();
    initializeSumInt(&state2);
    var typed2 = state2.getTypedState(SumStateInt);
    typed2.sum = 50;
    typed2.has_value = true;
    
    combineSumInt(&state1, &state2);
    
    try std.testing.expectEqual(@as(i128, 150), typed1.sum);
}

test "sum finalize null" {
    const allocator = std.testing.allocator;
    
    var state = AggregateState.init();
    initializeSumInt(&state);
    // No values added
    
    var output = try ValueVector.init(allocator, .INT64, 1);
    defer output.deinit();
    
    finalizeSumInt64(&state, &output, 0);
    
    try std.testing.expect(output.isNull(0));
}