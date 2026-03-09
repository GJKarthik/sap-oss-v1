//! MIN/MAX Aggregate Functions
//!
//! Converted from: kuzu/src/function/aggregate/min_max.cpp
//!
//! Purpose:
//! Implements MIN and MAX aggregate functions which find the minimum
//! and maximum values in a set.
//!
//! Mangle Integration:
//! The min/max semantics are also defined in aggregations.mg

const std = @import("std");
const common = @import("common");
const evaluator = @import("evaluator");
const function = @import("../function.zig");

const LogicalType = common.LogicalType;
const ValueVector = evaluator.ValueVector;
const AggregateState = function.AggregateState;
const AggregateFunction = function.AggregateFunction;
const FunctionParameter = function.FunctionParameter;
const FunctionCatalog = function.FunctionCatalog;

/// Generic MIN/MAX state for numeric types
pub const MinMaxStateNumeric = struct {
    value: i128, // Large enough for any integer
    has_value: bool,
    is_min: bool, // true = MIN, false = MAX
    
    pub fn init(is_min: bool) MinMaxStateNumeric {
        return .{
            .value = if (is_min) std.math.maxInt(i128) else std.math.minInt(i128),
            .has_value = false,
            .is_min = is_min,
        };
    }
    
    pub fn update(self: *MinMaxStateNumeric, new_value: i128) void {
        if (!self.has_value) {
            self.value = new_value;
            self.has_value = true;
        } else if (self.is_min) {
            if (new_value < self.value) {
                self.value = new_value;
            }
        } else {
            if (new_value > self.value) {
                self.value = new_value;
            }
        }
    }
};

/// MIN/MAX state for floating point types
pub const MinMaxStateFloat = struct {
    value: f64,
    has_value: bool,
    is_min: bool,
    
    pub fn init(is_min: bool) MinMaxStateFloat {
        return .{
            .value = if (is_min) std.math.inf(f64) else -std.math.inf(f64),
            .has_value = false,
            .is_min = is_min,
        };
    }
    
    pub fn update(self: *MinMaxStateFloat, new_value: f64) void {
        if (!self.has_value) {
            self.value = new_value;
            self.has_value = true;
        } else if (self.is_min) {
            if (new_value < self.value) {
                self.value = new_value;
            }
        } else {
            if (new_value > self.value) {
                self.value = new_value;
            }
        }
    }
};

// ============================================================================
// MIN Functions
// ============================================================================

/// Initialize MIN state for integers
fn initializeMinInt(state: *AggregateState) void {
    const typed = state.getTypedState(MinMaxStateNumeric);
    typed.* = MinMaxStateNumeric.init(true);
    state.is_initialized = true;
    state.is_null = true;
}

/// Initialize MIN state for floats
fn initializeMinFloat(state: *AggregateState) void {
    const typed = state.getTypedState(MinMaxStateFloat);
    typed.* = MinMaxStateFloat.init(true);
    state.is_initialized = true;
    state.is_null = true;
}

/// Update MIN(INT64) with all values
fn updateAllMinInt64(state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
    _ = multiplicity;
    const typed = state.getTypedState(MinMaxStateNumeric);
    
    const size = if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |i| {
        if (!input.isNull(i)) {
            if (input.getValue(i64, i)) |value| {
                typed.update(@as(i128, value));
                state.is_null = false;
            }
        }
    }
}

/// Update MIN(INT32) with all values
fn updateAllMinInt32(state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
    _ = multiplicity;
    const typed = state.getTypedState(MinMaxStateNumeric);
    
    const size = if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |i| {
        if (!input.isNull(i)) {
            if (input.getValue(i32, i)) |value| {
                typed.update(@as(i128, value));
                state.is_null = false;
            }
        }
    }
}

/// Update MIN(DOUBLE) with all values
fn updateAllMinDouble(state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
    _ = multiplicity;
    const typed = state.getTypedState(MinMaxStateFloat);
    
    const size = if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |i| {
        if (!input.isNull(i)) {
            if (input.getValue(f64, i)) |value| {
                typed.update(value);
                state.is_null = false;
            }
        }
    }
}

/// Combine two MIN integer states
fn combineMinInt(state: *AggregateState, other: *AggregateState) void {
    const typed = state.getTypedState(MinMaxStateNumeric);
    const other_typed = other.getTypedState(MinMaxStateNumeric);
    
    if (other_typed.has_value) {
        typed.update(other_typed.value);
        state.is_null = false;
    }
}

/// Combine two MIN float states
fn combineMinFloat(state: *AggregateState, other: *AggregateState) void {
    const typed = state.getTypedState(MinMaxStateFloat);
    const other_typed = other.getTypedState(MinMaxStateFloat);
    
    if (other_typed.has_value) {
        typed.update(other_typed.value);
        state.is_null = false;
    }
}

/// Finalize MIN(INT64) and write result
fn finalizeMinInt64(state: *AggregateState, output: *ValueVector, pos: u64) void {
    const typed = state.getTypedState(MinMaxStateNumeric);
    
    if (!typed.has_value) {
        output.setNull(pos, true);
    } else {
        output.setValue(i64, pos, @truncate(typed.value));
    }
}

/// Finalize MIN(DOUBLE) and write result
fn finalizeMinDouble(state: *AggregateState, output: *ValueVector, pos: u64) void {
    const typed = state.getTypedState(MinMaxStateFloat);
    
    if (!typed.has_value) {
        output.setNull(pos, true);
    } else {
        output.setValue(f64, pos, typed.value);
    }
}

// ============================================================================
// MAX Functions
// ============================================================================

/// Initialize MAX state for integers
fn initializeMaxInt(state: *AggregateState) void {
    const typed = state.getTypedState(MinMaxStateNumeric);
    typed.* = MinMaxStateNumeric.init(false);
    state.is_initialized = true;
    state.is_null = true;
}

/// Initialize MAX state for floats
fn initializeMaxFloat(state: *AggregateState) void {
    const typed = state.getTypedState(MinMaxStateFloat);
    typed.* = MinMaxStateFloat.init(false);
    state.is_initialized = true;
    state.is_null = true;
}

/// Update MAX(INT64) with all values
fn updateAllMaxInt64(state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
    _ = multiplicity;
    const typed = state.getTypedState(MinMaxStateNumeric);
    
    const size = if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |i| {
        if (!input.isNull(i)) {
            if (input.getValue(i64, i)) |value| {
                typed.update(@as(i128, value));
                state.is_null = false;
            }
        }
    }
}

/// Update MAX(DOUBLE) with all values
fn updateAllMaxDouble(state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
    _ = multiplicity;
    const typed = state.getTypedState(MinMaxStateFloat);
    
    const size = if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |i| {
        if (!input.isNull(i)) {
            if (input.getValue(f64, i)) |value| {
                typed.update(value);
                state.is_null = false;
            }
        }
    }
}

/// Combine two MAX integer states
fn combineMaxInt(state: *AggregateState, other: *AggregateState) void {
    const typed = state.getTypedState(MinMaxStateNumeric);
    const other_typed = other.getTypedState(MinMaxStateNumeric);
    
    if (other_typed.has_value) {
        typed.update(other_typed.value);
        state.is_null = false;
    }
}

/// Combine two MAX float states
fn combineMaxFloat(state: *AggregateState, other: *AggregateState) void {
    const typed = state.getTypedState(MinMaxStateFloat);
    const other_typed = other.getTypedState(MinMaxStateFloat);
    
    if (other_typed.has_value) {
        typed.update(other_typed.value);
        state.is_null = false;
    }
}

/// Register MIN/MAX functions with catalog
pub fn registerFunctions(catalog: *FunctionCatalog) !void {
    const int_types = [_]LogicalType{ .INT8, .INT16, .INT32, .INT64 };
    const float_types = [_]LogicalType{ .FLOAT, .DOUBLE };
    
    // MIN for integers
    for (int_types) |input_type| {
        var func = AggregateFunction.init(catalog.allocator, "MIN", input_type);
        try func.signature.addParameter(FunctionParameter.init("input", input_type));
        func.init_func = initializeMinInt;
        if (input_type == .INT64) {
            func.update_all_func = updateAllMinInt64;
        } else {
            func.update_all_func = updateAllMinInt32;
        }
        func.combine_func = combineMinInt;
        func.finalize_func = finalizeMinInt64;
        try catalog.registerAggregate(func);
    }
    
    // MIN for floats
    for (float_types) |input_type| {
        var func = AggregateFunction.init(catalog.allocator, "MIN", .DOUBLE);
        try func.signature.addParameter(FunctionParameter.init("input", input_type));
        func.init_func = initializeMinFloat;
        func.update_all_func = updateAllMinDouble;
        func.combine_func = combineMinFloat;
        func.finalize_func = finalizeMinDouble;
        try catalog.registerAggregate(func);
    }
    
    // MAX for integers
    for (int_types) |input_type| {
        var func = AggregateFunction.init(catalog.allocator, "MAX", input_type);
        try func.signature.addParameter(FunctionParameter.init("input", input_type));
        func.init_func = initializeMaxInt;
        if (input_type == .INT64) {
            func.update_all_func = updateAllMaxInt64;
        } else {
            func.update_all_func = updateAllMinInt32; // Uses same update logic
        }
        func.combine_func = combineMaxInt;
        func.finalize_func = finalizeMinInt64;
        try catalog.registerAggregate(func);
    }
    
    // MAX for floats
    for (float_types) |input_type| {
        var func = AggregateFunction.init(catalog.allocator, "MAX", .DOUBLE);
        try func.signature.addParameter(FunctionParameter.init("input", input_type));
        func.init_func = initializeMaxFloat;
        func.update_all_func = updateAllMaxDouble;
        func.combine_func = combineMaxFloat;
        func.finalize_func = finalizeMinDouble;
        try catalog.registerAggregate(func);
    }
}

/// Create standalone MIN function
pub fn createMinFunction(allocator: std.mem.Allocator, input_type: LogicalType) !AggregateFunction {
    const is_float = (input_type == .FLOAT or input_type == .DOUBLE);
    const return_type = if (is_float) LogicalType.DOUBLE else input_type;
    
    var func = AggregateFunction.init(allocator, "MIN", return_type);
    try func.signature.addParameter(FunctionParameter.init("input", input_type));
    
    if (is_float) {
        func.init_func = initializeMinFloat;
        func.update_all_func = updateAllMinDouble;
        func.combine_func = combineMinFloat;
        func.finalize_func = finalizeMinDouble;
    } else {
        func.init_func = initializeMinInt;
        func.update_all_func = updateAllMinInt64;
        func.combine_func = combineMinInt;
        func.finalize_func = finalizeMinInt64;
    }
    
    return func;
}

/// Create standalone MAX function
pub fn createMaxFunction(allocator: std.mem.Allocator, input_type: LogicalType) !AggregateFunction {
    const is_float = (input_type == .FLOAT or input_type == .DOUBLE);
    const return_type = if (is_float) LogicalType.DOUBLE else input_type;
    
    var func = AggregateFunction.init(allocator, "MAX", return_type);
    try func.signature.addParameter(FunctionParameter.init("input", input_type));
    
    if (is_float) {
        func.init_func = initializeMaxFloat;
        func.update_all_func = updateAllMaxDouble;
        func.combine_func = combineMaxFloat;
        func.finalize_func = finalizeMinDouble;
    } else {
        func.init_func = initializeMaxInt;
        func.update_all_func = updateAllMaxInt64;
        func.combine_func = combineMaxInt;
        func.finalize_func = finalizeMinInt64;
    }
    
    return func;
}

// ============================================================================
// Tests
// ============================================================================

test "min state numeric" {
    var state = MinMaxStateNumeric.init(true);
    try std.testing.expect(!state.has_value);
    try std.testing.expect(state.is_min);
    
    state.update(50);
    try std.testing.expect(state.has_value);
    try std.testing.expectEqual(@as(i128, 50), state.value);
    
    state.update(30);
    try std.testing.expectEqual(@as(i128, 30), state.value);
    
    state.update(70);
    try std.testing.expectEqual(@as(i128, 30), state.value); // Still 30 (min)
}

test "max state numeric" {
    var state = MinMaxStateNumeric.init(false);
    try std.testing.expect(!state.has_value);
    try std.testing.expect(!state.is_min);
    
    state.update(50);
    try std.testing.expect(state.has_value);
    try std.testing.expectEqual(@as(i128, 50), state.value);
    
    state.update(30);
    try std.testing.expectEqual(@as(i128, 50), state.value); // Still 50 (max)
    
    state.update(70);
    try std.testing.expectEqual(@as(i128, 70), state.value);
}

test "min float state" {
    var state = MinMaxStateFloat.init(true);
    try std.testing.expect(!state.has_value);
    
    state.update(5.5);
    try std.testing.expectApproxEqAbs(@as(f64, 5.5), state.value, 0.001);
    
    state.update(3.3);
    try std.testing.expectApproxEqAbs(@as(f64, 3.3), state.value, 0.001);
    
    state.update(7.7);
    try std.testing.expectApproxEqAbs(@as(f64, 3.3), state.value, 0.001); // Still min
}

test "max float state" {
    var state = MinMaxStateFloat.init(false);
    try std.testing.expect(!state.has_value);
    
    state.update(5.5);
    try std.testing.expectApproxEqAbs(@as(f64, 5.5), state.value, 0.001);
    
    state.update(7.7);
    try std.testing.expectApproxEqAbs(@as(f64, 7.7), state.value, 0.001);
    
    state.update(3.3);
    try std.testing.expectApproxEqAbs(@as(f64, 7.7), state.value, 0.001); // Still max
}

test "min int64 update" {
    const allocator = std.testing.allocator;
    
    var state = AggregateState.init();
    initializeMinInt(&state);
    
    var input = try ValueVector.init(allocator, .INT64, 5);
    defer input.deinit(allocator);
    
    input.setValue(i64, 0, 50);
    input.setValue(i64, 1, 30);
    input.setValue(i64, 2, 70);
    input.setValue(i64, 3, 20);
    input.setValue(i64, 4, 60);
    
    updateAllMinInt64(&state, &input, 1);
    
    const typed = state.getTypedState(MinMaxStateNumeric);
    try std.testing.expectEqual(@as(i128, 20), typed.value);
}

test "max int64 update" {
    const allocator = std.testing.allocator;
    
    var state = AggregateState.init();
    initializeMaxInt(&state);
    
    var input = try ValueVector.init(allocator, .INT64, 5);
    defer input.deinit(allocator);
    
    input.setValue(i64, 0, 50);
    input.setValue(i64, 1, 30);
    input.setValue(i64, 2, 70);
    input.setValue(i64, 3, 20);
    input.setValue(i64, 4, 60);
    
    updateAllMaxInt64(&state, &input, 1);
    
    const typed = state.getTypedState(MinMaxStateNumeric);
    try std.testing.expectEqual(@as(i128, 70), typed.value);
}

test "min finalize" {
    const allocator = std.testing.allocator;
    
    var state = AggregateState.init();
    initializeMinInt(&state);
    var typed = state.getTypedState(MinMaxStateNumeric);
    typed.value = 42;
    typed.has_value = true;
    
    var output = try ValueVector.init(allocator, .INT64, 1);
    defer output.deinit(allocator);
    
    finalizeMinInt64(&state, &output, 0);
    
    try std.testing.expectEqual(@as(?i64, 42), output.getValue(i64, 0));
}

test "min finalize null" {
    const allocator = std.testing.allocator;
    
    var state = AggregateState.init();
    initializeMinInt(&state);
    // No values added
    
    var output = try ValueVector.init(allocator, .INT64, 1);
    defer output.deinit(allocator);
    
    finalizeMinInt64(&state, &output, 0);
    
    try std.testing.expect(output.isNull(0));
}