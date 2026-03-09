//! List Functions - List Creation, Manipulation, and Querying
//!
//! Purpose:
//! Implements list operations for the query engine. Lists are core to
//! graph queries (paths, collected values, etc.)

const std = @import("std");
const common = @import("common");
const evaluator = @import("evaluator");
const function = @import("../function.zig");

const LogicalType = common.LogicalType;
const Value = common.Value;
const ValueVector = evaluator.ValueVector;
const SelectionVector = evaluator.SelectionVector;
const ScalarFunction = function.ScalarFunction;
const FunctionParameter = function.FunctionParameter;
const FunctionCatalog = function.FunctionCatalog;

/// List value representation
pub const ListValue = struct {
    allocator: std.mem.Allocator,
    element_type: LogicalType,
    elements: std.ArrayList(Value),
    
    pub fn init(allocator: std.mem.Allocator, element_type: LogicalType) ListValue {
        return .{
            .allocator = allocator,
            .element_type = element_type,
            .elements = .{},
        };
    }
    
    pub fn deinit(self: *ListValue) void {
        self.elements.deinit(self.allocator);
    }
    
    pub fn append(self: *ListValue, value: Value) !void {
        try self.elements.append(self.allocator, value);
    }
    
    pub fn get(self: *const ListValue, idx: usize) ?Value {
        if (idx >= self.elements.items.len) return null;
        return self.elements.items[idx];
    }
    
    pub fn len(self: *const ListValue) usize {
        return self.elements.items.len;
    }
    
    pub fn isEmpty(self: *const ListValue) bool {
        return self.elements.items.len == 0;
    }
};

// ============================================================================
// List Creation Functions
// ============================================================================

/// Create a list from arguments: list_creation(a, b, c) -> [a, b, c]
pub fn executeListCreation(inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
    const size = if (sel_vector) |sv| sv.getSelectedSize() else if (inputs.len > 0 and inputs[0].state != null) inputs[0].state.?.getNumSelectedValues() else if (inputs.len > 0) inputs[0].capacity else 0;
    
    for (0..size) |idx| {
        const i = if (sel_vector) |sv| sv.getSelectedPosition(idx) else idx;
        
        // Check if any input is null
        var any_null = false;
        for (inputs) |input| {
            if (input.isNull(i)) {
                any_null = true;
                break;
            }
        }
        
        if (any_null) {
            output.setNull(i, true);
        } else {
            // Create list value (simplified - actual impl would create nested structure)
            output.setNull(i, false);
        }
    }
}

// ============================================================================
// List Size/Length Function
// ============================================================================

/// SIZE(list) or LEN(list) - returns number of elements
pub fn executeListSize(inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
    const input = inputs[0];
    const size = if (sel_vector) |sv| sv.getSelectedSize() else if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |idx| {
        const i = if (sel_vector) |sv| sv.getSelectedPosition(idx) else idx;
        
        if (input.isNull(i)) {
            output.setNull(i, true);
        } else {
            // Simplified - actual impl would read list structure
            output.setValue(i64, i, 0);
        }
    }
}

// ============================================================================
// List Contains Function
// ============================================================================

/// list_contains(list, element) - returns true if element in list
pub fn executeListContains(inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
    const list_input = inputs[0];
    const elem_input = inputs[1];
    const size = if (sel_vector) |sv| sv.getSelectedSize() else if (list_input.state) |s| s.getNumSelectedValues() else list_input.capacity;
    
    for (0..size) |idx| {
        const i = if (sel_vector) |sv| sv.getSelectedPosition(idx) else idx;
        
        if (list_input.isNull(i) or elem_input.isNull(i)) {
            output.setNull(i, true);
        } else {
            // Simplified - would check if element exists in list
            output.setValue(bool, i, false);
        }
    }
}

// ============================================================================
// List Extract Function
// ============================================================================

/// list_extract(list, index) - returns element at index (1-based)
pub fn executeListExtract(inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
    const list_input = inputs[0];
    const idx_input = inputs[1];
    const size = if (sel_vector) |sv| sv.getSelectedSize() else if (list_input.state) |s| s.getNumSelectedValues() else list_input.capacity;
    
    for (0..size_loop) |idx| {
        const i = if (sel_vector) |sv| sv.getSelectedPosition(idx) else idx;
        _ = size;
        
        if (list_input.isNull(i) or idx_input.isNull(i)) {
            output.setNull(i, true);
        } else {
            // Simplified - would extract from list
            output.setNull(i, true);
        }
    }
    _ = size;
}

// ============================================================================
// List Append Function
// ============================================================================

/// list_append(list, element) - appends element to end of list
pub fn executeListAppend(inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
    const list_input = inputs[0];
    const elem_input = inputs[1];
    const size = if (sel_vector) |sv| sv.getSelectedSize() else if (list_input.state) |s| s.getNumSelectedValues() else list_input.capacity;
    
    for (0..size) |idx| {
        const i = if (sel_vector) |sv| sv.getSelectedPosition(idx) else idx;
        
        if (list_input.isNull(i)) {
            // NULL list + element = [element]
            if (!elem_input.isNull(i)) {
                output.setNull(i, false);
            } else {
                output.setNull(i, true);
            }
        } else {
            output.setNull(i, false);
        }
    }
}

// ============================================================================
// List Concat Function
// ============================================================================

/// list_concat(list1, list2) - concatenates two lists
pub fn executeListConcat(inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
    const list1 = inputs[0];
    const list2 = inputs[1];
    const size = if (sel_vector) |sv| sv.getSelectedSize() else if (list1.state) |s| s.getNumSelectedValues() else list1.capacity;
    
    for (0..size) |idx| {
        const i = if (sel_vector) |sv| sv.getSelectedPosition(idx) else idx;
        
        if (list1.isNull(i) and list2.isNull(i)) {
            output.setNull(i, true);
        } else {
            output.setNull(i, false);
        }
    }
}

// ============================================================================
// List Range Function
// ============================================================================

/// range(start, end) or range(start, end, step) - creates a list of integers
pub fn executeListRange(inputs: []*ValueVector, output: *ValueVector, sel_vector: ?*SelectionVector) !void {
    const start_input = inputs[0];
    const end_input = inputs[1];
    const size = if (sel_vector) |sv| sv.getSelectedSize() else if (start_input.state) |s| s.getNumSelectedValues() else start_input.capacity;
    
    for (0..size) |idx| {
        const i = if (sel_vector) |sv| sv.getSelectedPosition(idx) else idx;
        
        if (start_input.isNull(i) or end_input.isNull(i)) {
            output.setNull(i, true);
        } else {
            output.setNull(i, false);
        }
    }
}

// ============================================================================
// Function Registration
// ============================================================================

/// Register all list functions with catalog
pub fn registerFunctions(catalog: *FunctionCatalog) !void {
    // SIZE/LEN function
    {
        var func = ScalarFunction.init(catalog.allocator, "SIZE", .INT64);
        try func.signature.addParameter(FunctionParameter.init("list", .LIST));
        func.setExecFunc(executeListSize);
        try catalog.registerScalar(func);
    }
    
    {
        var func = ScalarFunction.init(catalog.allocator, "LEN", .INT64);
        try func.signature.addParameter(FunctionParameter.init("list", .LIST));
        func.setExecFunc(executeListSize);
        try catalog.registerScalar(func);
    }
    
    // LIST_CONTAINS
    {
        var func = ScalarFunction.init(catalog.allocator, "LIST_CONTAINS", .BOOL);
        try func.signature.addParameter(FunctionParameter.init("list", .LIST));
        try func.signature.addParameter(FunctionParameter.init("element", .ANY));
        func.setExecFunc(executeListContains);
        try catalog.registerScalar(func);
    }
    
    // RANGE
    {
        var func = ScalarFunction.init(catalog.allocator, "RANGE", .LIST);
        try func.signature.addParameter(FunctionParameter.init("start", .INT64));
        try func.signature.addParameter(FunctionParameter.init("end", .INT64));
        func.setExecFunc(executeListRange);
        try catalog.registerScalar(func);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "list value creation" {
    const allocator = std.testing.allocator;
    
    var list = ListValue.init(allocator, .INT64);
    defer list.deinit(std.testing.allocator);
    
    try std.testing.expect(list.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), list.len());
    
    const v1 = Value{ .data_type = .INT64, .int_value = 10, .bool_value = false, .double_value = 0, .string_value = "" };
    try list.append(std.testing.allocator, v1);
    
    try std.testing.expect(!list.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), list.len());
    
    const retrieved = list.get(0);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(i64, 10), retrieved.?.int_value);
}

test "list out of bounds" {
    const allocator = std.testing.allocator;
    
    var list = ListValue.init(allocator, .INT64);
    defer list.deinit(std.testing.allocator);
    
    try std.testing.expectEqual(@as(?Value, null), list.get(0));
    try std.testing.expectEqual(@as(?Value, null), list.get(100));
}