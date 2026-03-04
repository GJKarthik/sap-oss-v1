//! Cast Functions - Type Conversion Operations
//!
//! Purpose:
//! Implements type casting/conversion functions for the query engine.
//! Supports implicit and explicit casts between compatible types.

const std = @import("std");
const common = @import("../../common/common.zig");
const evaluator = @import("../../evaluator/evaluator.zig");
const function = @import("../function.zig");

const LogicalType = common.LogicalType;
const Value = common.Value;
const ValueVector = evaluator.ValueVector;
const SelectionVector = evaluator.SelectionVector;
const ScalarFunction = function.ScalarFunction;
const FunctionParameter = function.FunctionParameter;
const FunctionCatalog = function.FunctionCatalog;

/// Cast compatibility matrix
pub const CastType = enum {
    IMPLICIT,    // Automatic, safe (e.g., INT32 -> INT64)
    EXPLICIT,    // Requires CAST (e.g., DOUBLE -> INT64)
    IMPOSSIBLE,  // Cannot cast (e.g., STRING -> BOOL)
};

/// Check if cast is possible between types
pub fn getCastType(from: LogicalType, to: LogicalType) CastType {
    if (from == to) return .IMPLICIT;
    
    return switch (from) {
        .INT8 => switch (to) {
            .INT16, .INT32, .INT64, .INT128, .FLOAT, .DOUBLE => .IMPLICIT,
            .STRING => .EXPLICIT,
            else => .IMPOSSIBLE,
        },
        .INT16 => switch (to) {
            .INT32, .INT64, .INT128, .FLOAT, .DOUBLE => .IMPLICIT,
            .INT8 => .EXPLICIT,
            .STRING => .EXPLICIT,
            else => .IMPOSSIBLE,
        },
        .INT32 => switch (to) {
            .INT64, .INT128, .DOUBLE => .IMPLICIT,
            .FLOAT => .EXPLICIT, // May lose precision
            .INT8, .INT16 => .EXPLICIT,
            .STRING => .EXPLICIT,
            else => .IMPOSSIBLE,
        },
        .INT64 => switch (to) {
            .INT128, .DOUBLE => .IMPLICIT,
            .FLOAT => .EXPLICIT,
            .INT8, .INT16, .INT32 => .EXPLICIT,
            .STRING => .EXPLICIT,
            else => .IMPOSSIBLE,
        },
        .FLOAT => switch (to) {
            .DOUBLE => .IMPLICIT,
            .INT8, .INT16, .INT32, .INT64 => .EXPLICIT,
            .STRING => .EXPLICIT,
            else => .IMPOSSIBLE,
        },
        .DOUBLE => switch (to) {
            .FLOAT => .EXPLICIT,
            .INT8, .INT16, .INT32, .INT64 => .EXPLICIT,
            .STRING => .EXPLICIT,
            else => .IMPOSSIBLE,
        },
        .STRING => switch (to) {
            .INT8, .INT16, .INT32, .INT64 => .EXPLICIT,
            .FLOAT, .DOUBLE => .EXPLICIT,
            .BOOL => .EXPLICIT,
            .DATE, .TIMESTAMP => .EXPLICIT,
            else => .IMPOSSIBLE,
        },
        .BOOL => switch (to) {
            .STRING => .EXPLICIT,
            .INT8, .INT16, .INT32, .INT64 => .EXPLICIT,
            else => .IMPOSSIBLE,
        },
        else => .IMPOSSIBLE,
    };
}

// ============================================================================
// Cast Execution Functions
// ============================================================================

/// Cast INT64 to DOUBLE
pub fn executeCastInt64ToDouble(inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
    const input = inputs[0];
    const size = if (sel_vector) |sv| sv.getSelectedSize() else if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |idx| {
        const i = if (sel_vector) |sv| sv.getSelectedPosition(idx) else idx;
        
        if (input.isNull(i)) {
            output.setNull(i, true);
        } else {
            if (input.getValue(i64, i)) |value| {
                output.setValue(f64, i, @floatFromInt(value));
            }
        }
    }
}

/// Cast DOUBLE to INT64 (truncates)
pub fn executeCastDoubleToInt64(inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
    const input = inputs[0];
    const size = if (sel_vector) |sv| sv.getSelectedSize() else if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |idx| {
        const i = if (sel_vector) |sv| sv.getSelectedPosition(idx) else idx;
        
        if (input.isNull(i)) {
            output.setNull(i, true);
        } else {
            if (input.getValue(f64, i)) |value| {
                output.setValue(i64, i, @intFromFloat(value));
            }
        }
    }
}

/// Cast INT32 to INT64
pub fn executeCastInt32ToInt64(inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
    const input = inputs[0];
    const size = if (sel_vector) |sv| sv.getSelectedSize() else if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |idx| {
        const i = if (sel_vector) |sv| sv.getSelectedPosition(idx) else idx;
        
        if (input.isNull(i)) {
            output.setNull(i, true);
        } else {
            if (input.getValue(i32, i)) |value| {
                output.setValue(i64, i, @as(i64, value));
            }
        }
    }
}

/// Cast BOOL to INT64 (false=0, true=1)
pub fn executeCastBoolToInt64(inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
    const input = inputs[0];
    const size = if (sel_vector) |sv| sv.getSelectedSize() else if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |idx| {
        const i = if (sel_vector) |sv| sv.getSelectedPosition(idx) else idx;
        
        if (input.isNull(i)) {
            output.setNull(i, true);
        } else {
            if (input.getValue(bool, i)) |value| {
                output.setValue(i64, i, if (value) @as(i64, 1) else @as(i64, 0));
            }
        }
    }
}

/// Cast INT64 to BOOL (0=false, else=true)
pub fn executeCastInt64ToBool(inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
    const input = inputs[0];
    const size = if (sel_vector) |sv| sv.getSelectedSize() else if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |idx| {
        const i = if (sel_vector) |sv| sv.getSelectedPosition(idx) else idx;
        
        if (input.isNull(i)) {
            output.setNull(i, true);
        } else {
            if (input.getValue(i64, i)) |value| {
                output.setValue(bool, i, value != 0);
            }
        }
    }
}

// ============================================================================
// TRY_CAST - Returns NULL on failure instead of error
// ============================================================================

/// TRY_CAST(string AS INT64) - returns NULL if parse fails
pub fn executeTryCastStringToInt64(inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
    const input = inputs[0];
    const size = if (sel_vector) |sv| sv.getSelectedSize() else if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |idx| {
        const i = if (sel_vector) |sv| sv.getSelectedPosition(idx) else idx;
        
        if (input.isNull(i)) {
            output.setNull(i, true);
        } else {
            // Would parse string - simplified for now
            output.setNull(i, true);
        }
    }
}

// ============================================================================
// Function Registration
// ============================================================================

/// Register all cast functions with catalog
pub fn registerFunctions(catalog: *FunctionCatalog) !void {
    // CAST(INT64 AS DOUBLE)
    {
        var func = ScalarFunction.init(catalog.allocator, "CAST_INT64_TO_DOUBLE", .DOUBLE);
        try func.signature.addParameter(FunctionParameter.init("input", .INT64));
        func.setExecFunc(executeCastInt64ToDouble);
        try catalog.registerScalar(func);
    }
    
    // CAST(DOUBLE AS INT64)
    {
        var func = ScalarFunction.init(catalog.allocator, "CAST_DOUBLE_TO_INT64", .INT64);
        try func.signature.addParameter(FunctionParameter.init("input", .DOUBLE));
        func.setExecFunc(executeCastDoubleToInt64);
        try catalog.registerScalar(func);
    }
    
    // CAST(INT32 AS INT64)
    {
        var func = ScalarFunction.init(catalog.allocator, "CAST_INT32_TO_INT64", .INT64);
        try func.signature.addParameter(FunctionParameter.init("input", .INT32));
        func.setExecFunc(executeCastInt32ToInt64);
        try catalog.registerScalar(func);
    }
    
    // CAST(BOOL AS INT64)
    {
        var func = ScalarFunction.init(catalog.allocator, "CAST_BOOL_TO_INT64", .INT64);
        try func.signature.addParameter(FunctionParameter.init("input", .BOOL));
        func.setExecFunc(executeCastBoolToInt64);
        try catalog.registerScalar(func);
    }
    
    // CAST(INT64 AS BOOL)
    {
        var func = ScalarFunction.init(catalog.allocator, "CAST_INT64_TO_BOOL", .BOOL);
        try func.signature.addParameter(FunctionParameter.init("input", .INT64));
        func.setExecFunc(executeCastInt64ToBool);
        try catalog.registerScalar(func);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "cast compatibility matrix" {
    try std.testing.expectEqual(CastType.IMPLICIT, getCastType(.INT32, .INT64));
    try std.testing.expectEqual(CastType.IMPLICIT, getCastType(.INT64, .DOUBLE));
    try std.testing.expectEqual(CastType.EXPLICIT, getCastType(.DOUBLE, .INT64));
    try std.testing.expectEqual(CastType.EXPLICIT, getCastType(.STRING, .INT64));
    try std.testing.expectEqual(CastType.IMPOSSIBLE, getCastType(.LIST, .INT64));
}

test "cast int64 to double" {
    const allocator = std.testing.allocator;
    
    var input = try ValueVector.init(allocator, .INT64, 3);
    defer input.deinit();
    
    input.setValue(i64, 0, 100);
    input.setValue(i64, 1, -50);
    input.setNull(2, true);
    
    var output = try ValueVector.init(allocator, .DOUBLE, 3);
    defer output.deinit();
    
    var inputs = [_]*ValueVector{&input};
    try executeCastInt64ToDouble(&inputs, &output, null);
    
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), output.getValue(f64, 0).?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -50.0), output.getValue(f64, 1).?, 0.001);
    try std.testing.expect(output.isNull(2));
}

test "cast bool to int64" {
    const allocator = std.testing.allocator;
    
    var input = try ValueVector.init(allocator, .BOOL, 3);
    defer input.deinit();
    
    input.setValue(bool, 0, true);
    input.setValue(bool, 1, false);
    input.setNull(2, true);
    
    var output = try ValueVector.init(allocator, .INT64, 3);
    defer output.deinit();
    
    var inputs = [_]*ValueVector{&input};
    try executeCastBoolToInt64(&inputs, &output, null);
    
    try std.testing.expectEqual(@as(?i64, 1), output.getValue(i64, 0));
    try std.testing.expectEqual(@as(?i64, 0), output.getValue(i64, 1));
    try std.testing.expect(output.isNull(2));
}