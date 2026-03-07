//! Comparison Functions - Comparison Operations with Mangle Integration
//!
//! Converted from: kuzu/src/function/comparison_functions.cpp
//!
//! Purpose:
//! Implements comparison operators (=, <>, <, >, <=, >=) for all data types.
//! Integrates with Mangle rules.mg for declarative comparison semantics.
//!
//! Mangle Integration:
//! Comparison semantics defined in rules.mg enable pattern matching optimization

const std = @import("std");
const common = @import("../common/common.zig");
const evaluator = @import("../evaluator/evaluator.zig");
const function = @import("function.zig");

const LogicalType = common.LogicalType;
const Value = common.Value;
const ValueVector = evaluator.ValueVector;
const SelectionVector = evaluator.SelectionVector;
const ScalarFunction = function.ScalarFunction;
const FunctionParameter = function.FunctionParameter;
const FunctionCatalog = function.FunctionCatalog;

/// Comparison operation type
pub const ComparisonType = enum {
    EQUALS,
    NOT_EQUALS,
    LESS_THAN,
    LESS_THAN_OR_EQUAL,
    GREATER_THAN,
    GREATER_THAN_OR_EQUAL,
};

/// Generic comparison result
pub fn compare(comptime T: type, left: T, right: T, op: ComparisonType) bool {
    return switch (op) {
        .EQUALS => left == right,
        .NOT_EQUALS => left != right,
        .LESS_THAN => left < right,
        .LESS_THAN_OR_EQUAL => left <= right,
        .GREATER_THAN => left > right,
        .GREATER_THAN_OR_EQUAL => left >= right,
    };
}

// ============================================================================
// Comparison Execution Functions
// ============================================================================

/// Execute comparison for INT64
fn executeCompareInt64(op: ComparisonType, inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
    const left = inputs[0];
    const right = inputs[1];
    
    const size = if (sel_vector) |sv| sv.getSelectedSize() else if (left.state) |s| s.getNumSelectedValues() else left.capacity;
    
    for (0..size) |idx| {
        const i = if (sel_vector) |sv| sv.getSelectedPosition(idx) else idx;
        
        // Handle nulls - NULL comparison = NULL (except IS NULL)
        if (left.isNull(i) or right.isNull(i)) {
            output.setNull(i, true);
            continue;
        }
        
        const l = left.getValue(i64, i) orelse continue;
        const r = right.getValue(i64, i) orelse continue;
        
        output.setValue(bool, i, compare(i64, l, r, op));
    }
}

/// Execute comparison for DOUBLE
fn executeCompareDouble(op: ComparisonType, inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
    const left = inputs[0];
    const right = inputs[1];
    
    const size = if (sel_vector) |sv| sv.getSelectedSize() else if (left.state) |s| s.getNumSelectedValues() else left.capacity;
    
    for (0..size) |idx| {
        const i = if (sel_vector) |sv| sv.getSelectedPosition(idx) else idx;
        
        if (left.isNull(i) or right.isNull(i)) {
            output.setNull(i, true);
            continue;
        }
        
        const l = left.getValue(f64, i) orelse continue;
        const r = right.getValue(f64, i) orelse continue;
        
        output.setValue(bool, i, compare(f64, l, r, op));
    }
}

/// Execute comparison for BOOL
fn executeCompareBool(op: ComparisonType, inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
    const left = inputs[0];
    const right = inputs[1];
    
    const size = if (sel_vector) |sv| sv.getSelectedSize() else if (left.state) |s| s.getNumSelectedValues() else left.capacity;
    
    for (0..size) |idx| {
        const i = if (sel_vector) |sv| sv.getSelectedPosition(idx) else idx;
        
        if (left.isNull(i) or right.isNull(i)) {
            output.setNull(i, true);
            continue;
        }
        
        const l = left.getValue(bool, i) orelse continue;
        const r = right.getValue(bool, i) orelse continue;
        
        // For bool, only EQUALS and NOT_EQUALS are meaningful
        const result = switch (op) {
            .EQUALS => l == r,
            .NOT_EQUALS => l != r,
            else => l == r, // Default behavior
        };
        output.setValue(bool, i, result);
    }
}

// ============================================================================
// Select Functions (for predicate pushdown)
// ============================================================================

/// Select rows where comparison is true (INT64)
fn selectCompareInt64(op: ComparisonType, inputs: []*ValueVector, sel_vector: *SelectionVector) bool {
    const left = inputs[0];
    const right = inputs[1];
    
    var selected_count: u64 = 0;
    const size = sel_vector.getSelectedSize();
    
    for (0..size) |idx| {
        const i = sel_vector.getSelectedPosition(idx);
        
        // Skip nulls
        if (left.isNull(i) or right.isNull(i)) continue;
        
        const l = left.getValue(i64, i) orelse continue;
        const r = right.getValue(i64, i) orelse continue;
        
        if (compare(i64, l, r, op)) {
            sel_vector.setSelectedPosition(selected_count, i);
            selected_count += 1;
        }
    }
    
    sel_vector.setSelectedSize(selected_count);
    return selected_count > 0;
}

/// Select rows where comparison is true (DOUBLE)
fn selectCompareDouble(op: ComparisonType, inputs: []*ValueVector, sel_vector: *SelectionVector) bool {
    const left = inputs[0];
    const right = inputs[1];
    
    var selected_count: u64 = 0;
    const size = sel_vector.getSelectedSize();
    
    for (0..size) |idx| {
        const i = sel_vector.getSelectedPosition(idx);
        
        if (left.isNull(i) or right.isNull(i)) continue;
        
        const l = left.getValue(f64, i) orelse continue;
        const r = right.getValue(f64, i) orelse continue;
        
        if (compare(f64, l, r, op)) {
            sel_vector.setSelectedPosition(selected_count, i);
            selected_count += 1;
        }
    }
    
    sel_vector.setSelectedSize(selected_count);
    return selected_count > 0;
}

// ============================================================================
// Function Creators
// ============================================================================

/// Create EQUALS function for a type
pub fn createEqualsFunction(allocator: std.mem.Allocator, input_type: LogicalType) !ScalarFunction {
    var func = ScalarFunction.init(allocator, "EQUALS", .BOOL);
    try func.signature.addParameter(FunctionParameter.init("left", input_type));
    try func.signature.addParameter(FunctionParameter.init("right", input_type));
    
    // Set execution function based on type
    switch (input_type) {
        .INT64, .INT32, .INT16, .INT8 => {
            func.setExecFunc(struct {
                fn exec(inputs: []*ValueVector, output: *ValueVector, sv: ?*SelectionVector) !void {
                    try executeCompareInt64(.EQUALS, inputs, output, sv);
                }
            }.exec);
            func.setSelectFunc(struct {
                fn sel(inputs: []*ValueVector, sv: *SelectionVector) bool {
                    return selectCompareInt64(.EQUALS, inputs, sv);
                }
            }.sel);
        },
        .DOUBLE, .FLOAT => {
            func.setExecFunc(struct {
                fn exec(inputs: []*ValueVector, output: *ValueVector, sv: ?*SelectionVector) !void {
                    try executeCompareDouble(.EQUALS, inputs, output, sv);
                }
            }.exec);
            func.setSelectFunc(struct {
                fn sel(inputs: []*ValueVector, sv: *SelectionVector) bool {
                    return selectCompareDouble(.EQUALS, inputs, sv);
                }
            }.sel);
        },
        .BOOL => {
            func.setExecFunc(struct {
                fn exec(inputs: []*ValueVector, output: *ValueVector, sv: ?*SelectionVector) !void {
                    try executeCompareBool(.EQUALS, inputs, output, sv);
                }
            }.exec);
        },
        else => {},
    }
    
    return func;
}

/// Create LESS_THAN function for a type
pub fn createLessThanFunction(allocator: std.mem.Allocator, input_type: LogicalType) !ScalarFunction {
    var func = ScalarFunction.init(allocator, "LESS_THAN", .BOOL);
    try func.signature.addParameter(FunctionParameter.init("left", input_type));
    try func.signature.addParameter(FunctionParameter.init("right", input_type));
    
    switch (input_type) {
        .INT64, .INT32, .INT16, .INT8 => {
            func.setExecFunc(struct {
                fn exec(inputs: []*ValueVector, output: *ValueVector, sv: ?*SelectionVector) !void {
                    try executeCompareInt64(.LESS_THAN, inputs, output, sv);
                }
            }.exec);
            func.setSelectFunc(struct {
                fn sel(inputs: []*ValueVector, sv: *SelectionVector) bool {
                    return selectCompareInt64(.LESS_THAN, inputs, sv);
                }
            }.sel);
        },
        .DOUBLE, .FLOAT => {
            func.setExecFunc(struct {
                fn exec(inputs: []*ValueVector, output: *ValueVector, sv: ?*SelectionVector) !void {
                    try executeCompareDouble(.LESS_THAN, inputs, output, sv);
                }
            }.exec);
        },
        else => {},
    }
    
    return func;
}

/// Create GREATER_THAN function for a type
pub fn createGreaterThanFunction(allocator: std.mem.Allocator, input_type: LogicalType) !ScalarFunction {
    var func = ScalarFunction.init(allocator, "GREATER_THAN", .BOOL);
    try func.signature.addParameter(FunctionParameter.init("left", input_type));
    try func.signature.addParameter(FunctionParameter.init("right", input_type));
    
    switch (input_type) {
        .INT64, .INT32 => {
            func.setExecFunc(struct {
                fn exec(inputs: []*ValueVector, output: *ValueVector, sv: ?*SelectionVector) !void {
                    try executeCompareInt64(.GREATER_THAN, inputs, output, sv);
                }
            }.exec);
        },
        .DOUBLE, .FLOAT => {
            func.setExecFunc(struct {
                fn exec(inputs: []*ValueVector, output: *ValueVector, sv: ?*SelectionVector) !void {
                    try executeCompareDouble(.GREATER_THAN, inputs, output, sv);
                }
            }.exec);
        },
        else => {},
    }
    
    return func;
}

/// Register all comparison functions with catalog
pub fn registerFunctions(catalog: *FunctionCatalog) !void {
    const numeric_types = [_]LogicalType{ .INT8, .INT16, .INT32, .INT64, .FLOAT, .DOUBLE };
    
    for (numeric_types) |input_type| {
        // EQUALS
        var eq = try createEqualsFunction(catalog.allocator, input_type);
        try catalog.registerScalar(eq);
        
        // LESS_THAN
        var lt = try createLessThanFunction(catalog.allocator, input_type);
        try catalog.registerScalar(lt);
        
        // GREATER_THAN  
        var gt = try createGreaterThanFunction(catalog.allocator, input_type);
        try catalog.registerScalar(gt);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "compare int64" {
    try std.testing.expect(compare(i64, 10, 10, .EQUALS));
    try std.testing.expect(!compare(i64, 10, 20, .EQUALS));
    
    try std.testing.expect(compare(i64, 10, 20, .LESS_THAN));
    try std.testing.expect(!compare(i64, 20, 10, .LESS_THAN));
    
    try std.testing.expect(compare(i64, 20, 10, .GREATER_THAN));
    try std.testing.expect(compare(i64, 10, 10, .GREATER_THAN_OR_EQUAL));
    try std.testing.expect(compare(i64, 10, 10, .LESS_THAN_OR_EQUAL));
}

test "compare double" {
    try std.testing.expect(compare(f64, 1.5, 1.5, .EQUALS));
    try std.testing.expect(compare(f64, 1.0, 2.0, .LESS_THAN));
    try std.testing.expect(compare(f64, 2.0, 1.0, .GREATER_THAN));
}

test "compare bool" {
    try std.testing.expect(compare(bool, true, true, .EQUALS));
    try std.testing.expect(compare(bool, false, false, .EQUALS));
    try std.testing.expect(!compare(bool, true, false, .EQUALS));
    try std.testing.expect(compare(bool, true, false, .NOT_EQUALS));
}