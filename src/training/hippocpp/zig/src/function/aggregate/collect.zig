//! COLLECT Aggregate Function
//!
//! Purpose:
//! Implements the COLLECT aggregate function which collects values into a list.
//! This is the list aggregation function for graph queries.
//!
//! Mangle Integration:
//! The collect semantics are defined in aggregations.mg

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

/// COLLECT state - collects values into a dynamic list
pub const CollectState = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(common.Value),
    element_type: LogicalType,
    is_distinct: bool,
    seen_values: ?std.AutoHashMap(i64, void), // For distinct tracking (simplified)
    
    pub fn init(allocator: std.mem.Allocator, element_type: LogicalType, is_distinct: bool) CollectState {
        var state = CollectState{
            .allocator = allocator,
            .values = .{},
            .element_type = element_type,
            .is_distinct = is_distinct,
            .seen_values = null,
        };
        if (is_distinct) {
            state.seen_values = .{};
        }
        return state;
    }
    
    pub fn deinit(self: *CollectState) void {
        self.values.deinit(self.allocator);
        if (self.seen_values) |*seen| {
            seen.deinit();
        }
    }
    
    pub fn addValue(self: *CollectState, value: common.Value) !void {
        if (self.is_distinct) {
            // Simplified distinct check using int hash
            const hash = value.int_value;
            if (self.seen_values) |*seen| {
                if (seen.contains(hash)) return;
                try seen.put(hash, {});
            }
        }
        try self.values.append(self.allocator, value);
    }
    
    pub fn getCount(self: *const CollectState) usize {
        return self.values.items.len;
    }
};

/// Extended state buffer for collect (needs heap allocation pointer)
const CollectStateWrapper = struct {
    ptr: ?*CollectState,
    
    pub fn init() CollectStateWrapper {
        return .{ .ptr = null };
    }
};

/// Initialize COLLECT state
fn initializeCollect(state: *AggregateState) void {
    const typed = state.getTypedState(CollectStateWrapper);
    typed.* = CollectStateWrapper.init();
    state.is_initialized = true;
    state.is_null = false;
}

/// Update COLLECT(INT64) with all values
fn updateAllCollectInt64(state: *AggregateState, input: *ValueVector, multiplicity: u64) void {
    _ = multiplicity;
    const typed = state.getTypedState(CollectStateWrapper);
    
    // Lazy initialization
    if (typed.ptr == null) {
        // Note: In production, this would use proper allocator from context
        return;
    }
    
    const collect_state = typed.ptr.?;
    const size = if (input.state) |s| s.getNumSelectedValues() else input.capacity;
    
    for (0..size) |i| {
        if (!input.isNull(i)) {
            if (input.getValue(i64, i)) |value| {
                const v = common.Value{
                    .data_type = .INT64,
                    .int_value = value,
                    .bool_value = false,
                    .double_value = 0.0,
                    .string_value = "",
                };
                collect_state.addValue(v) catch {};
            }
        }
    }
}

/// Combine two COLLECT states
fn combineCollect(state: *AggregateState, other: *AggregateState) void {
    const typed = state.getTypedState(CollectStateWrapper);
    const other_typed = other.getTypedState(CollectStateWrapper);
    
    if (typed.ptr == null or other_typed.ptr == null) return;
    
    const collect_state = typed.ptr.?;
    const other_state = other_typed.ptr.?;
    
    for (other_state.values.items) |value| {
        collect_state.addValue(value) catch {};
    }
}

/// Finalize COLLECT - writes list to output
fn finalizeCollect(state: *AggregateState, output: *ValueVector, pos: u64) void {
    const typed = state.getTypedState(CollectStateWrapper);
    
    if (typed.ptr == null) {
        output.setNull(pos, true);
        return;
    }
    
    const collect_state = typed.ptr.?;
    if (collect_state.getCount() == 0) {
        // Empty list - set to empty LIST value
        output.setNull(pos, false);
    } else {
        // Write list value (simplified - actual implementation would serialize list)
        output.setNull(pos, false);
    }
}

/// Register COLLECT functions with catalog
pub fn registerFunctions(catalog: *FunctionCatalog) !void {
    const types = [_]LogicalType{
        .INT64, .INT32, .DOUBLE, .STRING, .BOOL,
    };
    
    for (types) |input_type| {
        // COLLECT(column)
        var collect_func = AggregateFunction.init(catalog.allocator, "COLLECT", .LIST);
        try collect_func.signature.addParameter(FunctionParameter.init("input", input_type));
        collect_func.init_func = initializeCollect;
        collect_func.update_all_func = updateAllCollectInt64;
        collect_func.combine_func = combineCollect;
        collect_func.finalize_func = finalizeCollect;
        try catalog.registerAggregate(collect_func);
        
        // COLLECT(DISTINCT column)
        var collect_distinct = AggregateFunction.init(catalog.allocator, "COLLECT", .LIST);
        try collect_distinct.signature.addParameter(FunctionParameter.init("input", input_type));
        collect_distinct.setDistinct(true);
        collect_distinct.init_func = initializeCollect;
        collect_distinct.update_all_func = updateAllCollectInt64;
        collect_distinct.combine_func = combineCollect;
        collect_distinct.finalize_func = finalizeCollect;
        try catalog.registerAggregate(collect_distinct);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "collect state" {
    const allocator = std.testing.allocator;
    
    var state = CollectState.init(allocator, .INT64, false);
    defer state.deinit(std.testing.allocator);
    
    try std.testing.expectEqual(@as(usize, 0), state.getCount());
    
    const v1 = common.Value{ .data_type = .INT64, .int_value = 10, .bool_value = false, .double_value = 0, .string_value = "" };
    try state.addValue(v1);
    try std.testing.expectEqual(@as(usize, 1), state.getCount());
    
    const v2 = common.Value{ .data_type = .INT64, .int_value = 20, .bool_value = false, .double_value = 0, .string_value = "" };
    try state.addValue(v2);
    try std.testing.expectEqual(@as(usize, 2), state.getCount());
}

test "collect distinct" {
    const allocator = std.testing.allocator;
    
    var state = CollectState.init(allocator, .INT64, true);
    defer state.deinit(std.testing.allocator);
    
    const v1 = common.Value{ .data_type = .INT64, .int_value = 10, .bool_value = false, .double_value = 0, .string_value = "" };
    try state.addValue(v1);
    try std.testing.expectEqual(@as(usize, 1), state.getCount());
    
    // Add duplicate - should not increase count
    try state.addValue(v1);
    try std.testing.expectEqual(@as(usize, 1), state.getCount());
    
    const v2 = common.Value{ .data_type = .INT64, .int_value = 20, .bool_value = false, .double_value = 0, .string_value = "" };
    try state.addValue(v2);
    try std.testing.expectEqual(@as(usize, 2), state.getCount());
}