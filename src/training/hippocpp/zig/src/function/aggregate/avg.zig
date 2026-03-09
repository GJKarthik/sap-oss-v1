//! AVG Aggregate Function
//!
//! Converted from: kuzu/src/function/aggregate/avg.cpp
//!
//! Purpose:
//! Implements the AVG aggregate function which computes the arithmetic
//! mean of numeric values. Returns DOUBLE for all input types.
//!
//! Mangle Integration:
//! The avg semantics are also defined in aggregations.mg:
//!   avg(X) :- sum(X) / count(X)

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

/// AVG state - tracks sum and count separately
pub const AvgState = struct {
    sum: f64,
    count: u64,
    
    pub fn init() AvgState {
        return .{
            .sum = 0.0,
            .count = 0,
        };
    }
    
    pub fn getAverage(self: *const AvgState) ?f64 {
        if (self.count == 0) return null;
        return self.sum / @as(f64, @floatFromInt(self.count));
    }
};

/// Initialize AVG state
fn initializeAvg(state: *AggregateState) void {
    const typed = state.getTypedState(AvgState);
    typed.* = AvgState.init();
    state.is_initialized = true;
    state.is_null = true; // AVG of no values is NULL
}

/// Update AVG with all INT64 values
fn updateAllAvgInt64(state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
    const typed = state.getTypedState(AvgState);
    
    const size = if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |i| {
        if (!input.isNull(i)) {
            if (input.getValue(i64, i)) |value| {
                typed.sum += @as(f64, @floatFromInt(value)) * @as(f64, @floatFromInt(multiplicity));
                typed.count += multiplicity;
                state.is_null = false;
            }
        }
    }
}

/// Update AVG with all INT32 values
fn updateAllAvgInt32(state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
    const typed = state.getTypedState(AvgState);
    
    const size = if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |i| {
        if (!input.isNull(i)) {
            if (input.getValue(i32, i)) |value| {
                typed.sum += @as(f64, @floatFromInt(value)) * @as(f64, @floatFromInt(multiplicity));
                typed.count += multiplicity;
                state.is_null = false;
            }
        }
    }
}

/// Update AVG with all DOUBLE values
fn updateAllAvgDouble(state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
    const typed = state.getTypedState(AvgState);
    
    const size = if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |i| {
        if (!input.isNull(i)) {
            if (input.getValue(f64, i)) |value| {
                typed.sum += value * @as(f64, @floatFromInt(multiplicity));
                typed.count += multiplicity;
                state.is_null = false;
            }
        }
    }
}

/// Update AVG with all FLOAT values
fn updateAllAvgFloat(state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
    const typed = state.getTypedState(AvgState);
    
    const size = if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |i| {
        if (!input.isNull(i)) {
            if (input.getValue(f32, i)) |value| {
                typed.sum += @as(f64, value) * @as(f64, @floatFromInt(multiplicity));
                typed.count += multiplicity;
                state.is_null = false;
            }
        }
    }
}

/// Update AVG(INT64) at specific position
fn updatePosAvgInt64(state: *AggregateState, input: *ValueVector, pos: u64, multiplicity: u64) void {
    const typed = state.getTypedState(AvgState);
    
    if (!input.isNull(pos)) {
        if (input.getValue(i64, pos)) |value| {
            typed.sum += @as(f64, @floatFromInt(value)) * @as(f64, @floatFromInt(multiplicity));
            typed.count += multiplicity;
            state.is_null = false;
        }
    }
}

/// Update AVG(DOUBLE) at specific position
fn updatePosAvgDouble(state: *AggregateState, input: *ValueVector, pos: u64, multiplicity: u64) void {
    const typed = state.getTypedState(AvgState);
    
    if (!input.isNull(pos)) {
        if (input.getValue(f64, pos)) |value| {
            typed.sum += value * @as(f64, @floatFromInt(multiplicity));
            typed.count += multiplicity;
            state.is_null = false;
        }
    }
}

/// Combine two AVG states
fn combineAvg(state: *AggregateState, other: *AggregateState) void {
    const typed = state.getTypedState(AvgState);
    const other_typed = other.getTypedState(AvgState);
    
    if (other_typed.count > 0) {
        typed.sum += other_typed.sum;
        typed.count += other_typed.count;
        state.is_null = false;
    }
}

/// Finalize AVG and write result
fn finalizeAvg(state: *AggregateState, output: *ValueVector, pos: u64) void {
    const typed = state.getTypedState(AvgState);
    
    if (typed.count == 0) {
        output.setNull(pos, true);
    } else {
        const avg = typed.sum / @as(f64, @floatFromInt(typed.count));
        output.setValue(f64, pos, avg);
    }
}

/// Register AVG functions with catalog
pub fn registerFunctions(catalog: *FunctionCatalog) !void {
    // AVG(INT8) -> DOUBLE
    {
        var func = AggregateFunction.init(catalog.allocator, "AVG", .DOUBLE);
        try func.signature.addParameter(FunctionParameter.init("input", .INT8));
        func.init_func = initializeAvg;
        func.update_all_func = updateAllAvgInt32;
        func.combine_func = combineAvg;
        func.finalize_func = finalizeAvg;
        try catalog.registerAggregate(func);
    }
    
    // AVG(INT16) -> DOUBLE
    {
        var func = AggregateFunction.init(catalog.allocator, "AVG", .DOUBLE);
        try func.signature.addParameter(FunctionParameter.init("input", .INT16));
        func.init_func = initializeAvg;
        func.update_all_func = updateAllAvgInt32;
        func.combine_func = combineAvg;
        func.finalize_func = finalizeAvg;
        try catalog.registerAggregate(func);
    }
    
    // AVG(INT32) -> DOUBLE
    {
        var func = AggregateFunction.init(catalog.allocator, "AVG", .DOUBLE);
        try func.signature.addParameter(FunctionParameter.init("input", .INT32));
        func.init_func = initializeAvg;
        func.update_all_func = updateAllAvgInt32;
        func.combine_func = combineAvg;
        func.finalize_func = finalizeAvg;
        try catalog.registerAggregate(func);
    }
    
    // AVG(INT64) -> DOUBLE
    {
        var func = AggregateFunction.init(catalog.allocator, "AVG", .DOUBLE);
        try func.signature.addParameter(FunctionParameter.init("input", .INT64));
        func.init_func = initializeAvg;
        func.update_all_func = updateAllAvgInt64;
        func.update_pos_func = updatePosAvgInt64;
        func.combine_func = combineAvg;
        func.finalize_func = finalizeAvg;
        try catalog.registerAggregate(func);
    }
    
    // AVG(FLOAT) -> DOUBLE
    {
        var func = AggregateFunction.init(catalog.allocator, "AVG", .DOUBLE);
        try func.signature.addParameter(FunctionParameter.init("input", .FLOAT));
        func.init_func = initializeAvg;
        func.update_all_func = updateAllAvgFloat;
        func.combine_func = combineAvg;
        func.finalize_func = finalizeAvg;
        try catalog.registerAggregate(func);
    }
    
    // AVG(DOUBLE) -> DOUBLE
    {
        var func = AggregateFunction.init(catalog.allocator, "AVG", .DOUBLE);
        try func.signature.addParameter(FunctionParameter.init("input", .DOUBLE));
        func.init_func = initializeAvg;
        func.update_all_func = updateAllAvgDouble;
        func.update_pos_func = updatePosAvgDouble;
        func.combine_func = combineAvg;
        func.finalize_func = finalizeAvg;
        try catalog.registerAggregate(func);
    }
}

/// Create a standalone AVG function for integers
pub fn createAvgIntFunction(allocator: std.mem.Allocator, input_type: LogicalType) !AggregateFunction {
    var func = AggregateFunction.init(allocator, "AVG", .DOUBLE);
    try func.signature.addParameter(FunctionParameter.init("input", input_type));
    func.init_func = initializeAvg;
    func.update_all_func = updateAllAvgInt64;
    func.update_pos_func = updatePosAvgInt64;
    func.combine_func = combineAvg;
    func.finalize_func = finalizeAvg;
    return func;
}

/// Create a standalone AVG function for floats
pub fn createAvgFloatFunction(allocator: std.mem.Allocator, input_type: LogicalType) !AggregateFunction {
    var func = AggregateFunction.init(allocator, "AVG", .DOUBLE);
    try func.signature.addParameter(FunctionParameter.init("input", input_type));
    func.init_func = initializeAvg;
    func.update_all_func = updateAllAvgDouble;
    func.update_pos_func = updatePosAvgDouble;
    func.combine_func = combineAvg;
    func.finalize_func = finalizeAvg;
    return func;
}

// ============================================================================
// Tests
// ============================================================================

test "avg state" {
    var state = AggregateState.init();
    initializeAvg(&state);
    
    try std.testing.expect(state.is_initialized);
    try std.testing.expect(state.is_null);
    
    const typed = state.getTypedState(AvgState);
    try std.testing.expectEqual(@as(f64, 0.0), typed.sum);
    try std.testing.expectEqual(@as(u64, 0), typed.count);
    try std.testing.expectEqual(@as(?f64, null), typed.getAverage());
}

test "avg state average calculation" {
    var avg_state = AvgState.init();
    avg_state.sum = 100.0;
    avg_state.count = 4;
    
    const avg = avg_state.getAverage();
    try std.testing.expect(avg != null);
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), avg.?, 0.001);
}

test "avg int64 update" {
    const allocator = std.testing.allocator;
    
    var state = AggregateState.init();
    initializeAvg(&state);
    
    var input = try ValueVector.init(allocator, .INT64, 4);
    defer input.deinit(allocator);
    
    input.setValue(i64, 0, 10);
    input.setValue(i64, 1, 20);
    input.setValue(i64, 2, 30);
    input.setValue(i64, 3, 40);
    
    updateAllAvgInt64(&state, &input, 1);
    
    const typed = state.getTypedState(AvgState);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), typed.sum, 0.001);
    try std.testing.expectEqual(@as(u64, 4), typed.count);
    
    const avg = typed.getAverage();
    try std.testing.expect(avg != null);
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), avg.?, 0.001);
}

test "avg double update" {
    const allocator = std.testing.allocator;
    
    var state = AggregateState.init();
    initializeAvg(&state);
    
    var input = try ValueVector.init(allocator, .DOUBLE, 3);
    defer input.deinit(allocator);
    
    input.setValue(f64, 0, 1.0);
    input.setValue(f64, 1, 2.0);
    input.setValue(f64, 2, 3.0);
    
    updateAllAvgDouble(&state, &input, 1);
    
    const typed = state.getTypedState(AvgState);
    const avg = typed.getAverage();
    try std.testing.expect(avg != null);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), avg.?, 0.001);
}

test "avg combine" {
    var state1 = AggregateState.init();
    initializeAvg(&state1);
    var typed1 = state1.getTypedState(AvgState);
    typed1.sum = 100.0;
    typed1.count = 4;
    
    var state2 = AggregateState.init();
    initializeAvg(&state2);
    var typed2 = state2.getTypedState(AvgState);
    typed2.sum = 50.0;
    typed2.count = 2;
    
    combineAvg(&state1, &state2);
    
    try std.testing.expectApproxEqAbs(@as(f64, 150.0), typed1.sum, 0.001);
    try std.testing.expectEqual(@as(u64, 6), typed1.count);
    
    const avg = typed1.getAverage();
    try std.testing.expect(avg != null);
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), avg.?, 0.001);
}

test "avg finalize" {
    const allocator = std.testing.allocator;
    
    var state = AggregateState.init();
    initializeAvg(&state);
    var typed = state.getTypedState(AvgState);
    typed.sum = 100.0;
    typed.count = 4;
    
    var output = try ValueVector.init(allocator, .DOUBLE, 1);
    defer output.deinit(allocator);
    
    finalizeAvg(&state, &output, 0);
    
    const result = output.getValue(f64, 0);
    try std.testing.expect(result != null);
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), result.?, 0.001);
}

test "avg finalize null" {
    const allocator = std.testing.allocator;
    
    var state = AggregateState.init();
    initializeAvg(&state);
    // No values added - count is 0
    
    var output = try ValueVector.init(allocator, .DOUBLE, 1);
    defer output.deinit(allocator);
    
    finalizeAvg(&state, &output, 0);
    
    try std.testing.expect(output.isNull(0));
}

test "avg with nulls" {
    const allocator = std.testing.allocator;
    
    var state = AggregateState.init();
    initializeAvg(&state);
    
    var input = try ValueVector.init(allocator, .INT64, 5);
    defer input.deinit(allocator);
    
    input.setValue(i64, 0, 10);
    input.setNull(1, true); // NULL - should be skipped
    input.setValue(i64, 2, 20);
    input.setNull(3, true); // NULL - should be skipped
    input.setValue(i64, 4, 30);
    
    updateAllAvgInt64(&state, &input, 1);
    
    const typed = state.getTypedState(AvgState);
    // Should only have 3 non-null values
    try std.testing.expectEqual(@as(u64, 3), typed.count);
    try std.testing.expectApproxEqAbs(@as(f64, 60.0), typed.sum, 0.001);
    
    const avg = typed.getAverage();
    try std.testing.expect(avg != null);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), avg.?, 0.001);
}