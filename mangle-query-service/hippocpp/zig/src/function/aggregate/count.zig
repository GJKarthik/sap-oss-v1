//! COUNT Aggregate Function
//!
//! Converted from: kuzu/src/function/aggregate/count.cpp
//!
//! Purpose:
//! Implements the COUNT aggregate function which counts non-null values
//! or all rows (COUNT(*)).
//!
//! Mangle Integration:
//! The count semantics are also defined in aggregations.mg:
//!   count(X) :- ... aggregate ...

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

/// COUNT aggregate state
pub const CountState = struct {
    count: i64,
    
    pub fn init() CountState {
        return .{ .count = 0 };
    }
};

/// Initialize COUNT state
fn initializeCount(state: *AggregateState) void {
    const typed = state.getTypedState(CountState);
    typed.* = CountState.init();
    state.is_initialized = true;
    state.is_null = false;
}

/// Update COUNT with all values (COUNT with non-null filter)
fn updateAllCount(state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
    const typed = state.getTypedState(CountState);
    
    // Count non-null values
    const non_null_count = input.countNonNull();
    typed.count += @intCast(multiplicity * non_null_count);
}

/// Update COUNT at specific position
fn updatePosCount(state: *AggregateState, input: *ValueVector, pos: u64, multiplicity: u64) void {
    const typed = state.getTypedState(CountState);
    
    // Only count if not null
    if (!input.isNull(pos)) {
        typed.count += @intCast(multiplicity);
    }
}

/// Combine two COUNT states
fn combineCount(state: *AggregateState, other: *AggregateState) void {
    const typed = state.getTypedState(CountState);
    const other_typed = other.getTypedState(CountState);
    typed.count += other_typed.count;
}

/// Finalize COUNT and write result
fn finalizeCount(state: *AggregateState, output: *ValueVector, pos: u64) void {
    const typed = state.getTypedState(CountState);
    output.setValue(i64, pos, typed.count);
}

/// COUNT(*) aggregate state - counts all rows
pub const CountStarState = struct {
    count: i64,
    
    pub fn init() CountStarState {
        return .{ .count = 0 };
    }
};

/// Initialize COUNT(*) state
fn initializeCountStar(state: *AggregateState) void {
    const typed = state.getTypedState(CountStarState);
    typed.* = CountStarState.init();
    state.is_initialized = true;
    state.is_null = false;
}

/// Update COUNT(*) with all values (counts everything including nulls)
fn updateAllCountStar(state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
    const typed = state.getTypedState(CountStarState);
    
    // Count all rows (capacity or selected size)
    const count = if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    typed.count += @intCast(multiplicity * count);
}

/// Update COUNT(*) at specific position (always counts)
fn updatePosCountStar(state: *AggregateState, input: *ValueVector, pos: u64, multiplicity: u64) void {
    _ = input;
    _ = pos;
    const typed = state.getTypedState(CountStarState);
    typed.count += @intCast(multiplicity);
}

/// Combine two COUNT(*) states
fn combineCountStar(state: *AggregateState, other: *AggregateState) void {
    const typed = state.getTypedState(CountStarState);
    const other_typed = other.getTypedState(CountStarState);
    typed.count += other_typed.count;
}

/// Finalize COUNT(*) and write result
fn finalizeCountStar(state: *AggregateState, output: *ValueVector, pos: u64) void {
    const typed = state.getTypedState(CountStarState);
    output.setValue(i64, pos, typed.count);
}

/// Register COUNT functions with catalog
pub fn registerFunctions(catalog: *FunctionCatalog) !void {
    // Register COUNT for all types
    const types = [_]LogicalType{
        .BOOL,     .INT8,   .INT16,   .INT32,   .INT64,   .INT128,
        .UINT8,    .UINT16, .UINT32,  .UINT64,  .UINT128, .FLOAT,
        .DOUBLE,   .STRING, .DATE,    .TIMESTAMP,
        .INTERNAL_ID, .LIST, .STRUCT, .MAP,
    };
    
    for (types) |input_type| {
        // COUNT(column) - counts non-null values
        var count_func = AggregateFunction.init(catalog.allocator, "COUNT", .INT64);
        try count_func.signature.addParameter(FunctionParameter.init("input", input_type));
        count_func.setNeedsToHandleNulls(true);
        count_func.init_func = initializeCount;
        count_func.update_all_func = updateAllCount;
        count_func.update_pos_func = updatePosCount;
        count_func.combine_func = combineCount;
        count_func.finalize_func = finalizeCount;
        try catalog.registerAggregate(count_func);
        
        // COUNT(DISTINCT column)
        var count_distinct = AggregateFunction.init(catalog.allocator, "COUNT", .INT64);
        try count_distinct.signature.addParameter(FunctionParameter.init("input", input_type));
        count_distinct.setDistinct(true);
        count_distinct.setNeedsToHandleNulls(true);
        count_distinct.init_func = initializeCount;
        count_distinct.update_all_func = updateAllCount;
        count_distinct.update_pos_func = updatePosCount;
        count_distinct.combine_func = combineCount;
        count_distinct.finalize_func = finalizeCount;
        try catalog.registerAggregate(count_distinct);
    }
    
    // COUNT(*) - counts all rows
    var count_star = AggregateFunction.init(catalog.allocator, "COUNT_STAR", .INT64);
    count_star.init_func = initializeCountStar;
    count_star.update_all_func = updateAllCountStar;
    count_star.update_pos_func = updatePosCountStar;
    count_star.combine_func = combineCountStar;
    count_star.finalize_func = finalizeCountStar;
    try catalog.registerAggregate(count_star);
}

/// Create a standalone COUNT function for a specific type
pub fn createCountFunction(allocator: std.mem.Allocator, input_type: LogicalType, is_distinct: bool) !AggregateFunction {
    var func = AggregateFunction.init(allocator, "COUNT", .INT64);
    try func.signature.addParameter(FunctionParameter.init("input", input_type));
    func.setDistinct(is_distinct);
    func.setNeedsToHandleNulls(true);
    func.init_func = initializeCount;
    func.update_all_func = updateAllCount;
    func.update_pos_func = updatePosCount;
    func.combine_func = combineCount;
    func.finalize_func = finalizeCount;
    return func;
}

/// Create COUNT(*) function
pub fn createCountStarFunction(allocator: std.mem.Allocator) AggregateFunction {
    var func = AggregateFunction.init(allocator, "COUNT_STAR", .INT64);
    func.init_func = initializeCountStar;
    func.update_all_func = updateAllCountStar;
    func.update_pos_func = updatePosCountStar;
    func.combine_func = combineCountStar;
    func.finalize_func = finalizeCountStar;
    return func;
}

// ============================================================================
// Tests
// ============================================================================

test "count state" {
    var state = AggregateState.init();
    initializeCount(&state);
    
    try std.testing.expect(state.is_initialized);
    try std.testing.expect(!state.is_null);
    
    const typed = state.getTypedState(CountState);
    try std.testing.expectEqual(@as(i64, 0), typed.count);
}

test "count update" {
    const allocator = std.testing.allocator;
    
    var state = AggregateState.init();
    initializeCount(&state);
    
    // Create input vector with some values
    var input = try ValueVector.init(allocator, .INT64, 10);
    defer input.deinit();
    
    // Set some values, some null
    input.setValue(i64, 0, 1);
    input.setValue(i64, 1, 2);
    input.setNull(2, true);
    input.setValue(i64, 3, 3);
    input.setNull(4, true);
    input.setAllNonNull(); // Clear null mask first
    input.setNull(2, true);
    input.setNull(4, true);
    
    // Update state
    updateAllCount(&state, &input, 1);
    
    const typed = state.getTypedState(CountState);
    // Should count non-null values
    try std.testing.expectEqual(@as(i64, 8), typed.count);
}

test "count combine" {
    var state1 = AggregateState.init();
    initializeCount(&state1);
    var typed1 = state1.getTypedState(CountState);
    typed1.count = 5;
    
    var state2 = AggregateState.init();
    initializeCount(&state2);
    var typed2 = state2.getTypedState(CountState);
    typed2.count = 3;
    
    combineCount(&state1, &state2);
    
    try std.testing.expectEqual(@as(i64, 8), typed1.count);
}

test "count finalize" {
    const allocator = std.testing.allocator;
    
    var state = AggregateState.init();
    initializeCount(&state);
    var typed = state.getTypedState(CountState);
    typed.count = 42;
    
    var output = try ValueVector.init(allocator, .INT64, 10);
    defer output.deinit();
    
    finalizeCount(&state, &output, 0);
    
    try std.testing.expectEqual(@as(?i64, 42), output.getValue(i64, 0));
}

test "count star" {
    const allocator = std.testing.allocator;
    
    var state = AggregateState.init();
    initializeCountStar(&state);
    
    var input = try ValueVector.init(allocator, .INT64, 10);
    defer input.deinit();
    
    // Even with nulls, COUNT(*) counts all
    input.setNull(0, true);
    input.setNull(1, true);
    
    updateAllCountStar(&state, &input, 1);
    
    const typed = state.getTypedState(CountStarState);
    // Should count all rows
    try std.testing.expectEqual(@as(i64, 10), typed.count);
}