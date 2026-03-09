//! Expression Evaluator - Core Expression Evaluation Engine
//!
//! Converted from: kuzu/src/expression_evaluator/expression_evaluator.cpp
//!
//! Purpose:
//! Evaluates expressions during query execution. Supports scalar expressions,
//! aggregate functions, and predicates. Integrates with Mangle for declarative
//! evaluation rules.
//!
//! Architecture:
//! ```
//! ExpressionEvaluator (Base)
//!   ├── LiteralEvaluator      - Constant values
//!   ├── ReferenceEvaluator    - Column references
//!   ├── FunctionEvaluator     - Scalar functions
//!   ├── AggregateEvaluator    - Aggregate functions
//!   ├── CaseEvaluator         - CASE WHEN expressions
//!   ├── PathEvaluator         - Graph path expressions
//!   └── PatternEvaluator      - Graph pattern matching
//! ```

const std = @import("std");
const common = @import("common");

const LogicalType = common.LogicalType;
const Value = common.Value;

/// Expression type enumeration
pub const ExpressionType = enum(u8) {
    LITERAL = 0,
    REFERENCE = 1,
    FUNCTION = 2,
    AGGREGATE = 3,
    CASE = 4,
    PATH = 5,
    PATTERN = 6,
    COMPARISON = 7,
    BOOLEAN = 8,
    PROPERTY = 9,
    PARAMETER = 10,
    SUBQUERY = 11,
    LAMBDA = 12,
    STAR = 13,
    NODE = 14,
    REL = 15,
    LIST = 16,
    MAP = 17,
    STRUCT = 18,
    INTERNAL_ID = 19,
};

/// Selection vector for filtered evaluation
pub const SelectionVector = struct {
    allocator: std.mem.Allocator,
    selected_positions: []u64,
    selected_size: u64,
    is_unfiltered: bool,
    capacity: u64,
    
    const Self = @This();
    
    pub const DEFAULT_CAPACITY: u64 = 2048;
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self.initWithCapacity(allocator, DEFAULT_CAPACITY);
    }
    
    pub fn initWithCapacity(allocator: std.mem.Allocator, capacity: u64) !Self {
        const positions = try allocator.alloc(u64, capacity);
        // Initialize as unfiltered (all positions selected)
        for (positions, 0..) |*pos, i| {
            pos.* = i;
        }
        return .{
            .allocator = allocator,
            .selected_positions = positions,
            .selected_size = capacity,
            .is_unfiltered = true,
            .capacity = capacity,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.selected_positions);
    }
    
    pub fn isUnfiltered(self: *const Self) bool {
        return self.is_unfiltered;
    }
    
    pub fn setToFiltered(self: *Self) void {
        self.is_unfiltered = false;
    }
    
    pub fn setToUnfiltered(self: *Self) void {
        self.is_unfiltered = true;
    }
    
    pub fn getSelectedSize(self: *const Self) u64 {
        return self.selected_size;
    }
    
    pub fn setSelectedSize(self: *Self, size: u64) void {
        self.selected_size = size;
    }
    
    pub fn getSelectedPosition(self: *const Self, idx: u64) u64 {
        if (self.is_unfiltered) return idx;
        return self.selected_positions[idx];
    }
    
    pub fn setSelectedPosition(self: *Self, idx: u64, pos: u64) void {
        self.selected_positions[idx] = pos;
    }
};

/// Data chunk state - shared state between vectors in a data chunk
pub const DataChunkState = struct {
    allocator: std.mem.Allocator,
    selection_vector: ?*SelectionVector,
    original_size: u64,
    num_selected_values: u64,
    is_flat: bool,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .selection_vector = null,
            .original_size = 0,
            .num_selected_values = 0,
            .is_flat = false,
        };
    }
    
    pub fn initOriginalAndSelectedSize(self: *Self, size: u64) void {
        self.original_size = size;
        self.num_selected_values = size;
    }
    
    pub fn setToFlat(self: *Self) void {
        self.is_flat = true;
    }
    
    pub fn setToUnflat(self: *Self) void {
        self.is_flat = false;
    }
    
    pub fn isFlat(self: *const Self) bool {
        return self.is_flat;
    }
    
    pub fn getNumSelectedValues(self: *const Self) u64 {
        return self.num_selected_values;
    }
    
    pub fn setNumSelectedValues(self: *Self, num: u64) void {
        self.num_selected_values = num;
    }
};

/// Value vector - columnar storage for expression results
pub const ValueVector = struct {
    allocator: std.mem.Allocator,
    data_type: LogicalType,
    state: ?*DataChunkState,
    null_mask: []bool,
    data: []u8,
    capacity: u64,
    num_bytes_per_value: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, data_type: LogicalType, capacity: u64) !Self {
        const bytes_per_value = getBytesPerValue(data_type);
        return .{
            .allocator = allocator,
            .data_type = data_type,
            .state = null,
            .null_mask = try allocator.alloc(bool, capacity),
            .data = try allocator.alloc(u8, capacity * bytes_per_value),
            .capacity = capacity,
            .num_bytes_per_value = bytes_per_value,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.null_mask);
        self.allocator.free(self.data);
    }
    
    fn getBytesPerValue(data_type: LogicalType) u64 {
        return switch (data_type.type_id) {
            .BOOL => 1,
            .INT8 => 1,
            .INT16 => 2,
            .INT32 => 4,
            .INT64 => 8,
            .INT128 => 16,
            .UINT8 => 1,
            .UINT16 => 2,
            .UINT32 => 4,
            .UINT64 => 8,
    // .UINT128 => 16,
            .FLOAT => 4,
            .DOUBLE => 8,
            .STRING => 16,
            .INTERNAL_ID => 16,
            else => 8,
        };
    }
    
    pub fn setState(self: *Self, state: *DataChunkState) void {
        self.state = state;
    }
    
    pub fn isNull(self: *const Self, pos: u64) bool {
        if (pos >= self.capacity) return true;
        return self.null_mask[pos];
    }
    
    pub fn setNull(self: *Self, pos: u64, is_null: bool) void {
        if (pos < self.capacity) {
            self.null_mask[pos] = is_null;
        }
    }
    
    pub fn getValue(self: *const Self, comptime T: type, pos: u64) ?T {
        if (self.isNull(pos)) return null;
        const offset = pos * self.num_bytes_per_value;
        const ptr: *const T = @ptrCast(@alignCast(&self.data[offset]));
        return ptr.*;
    }
    
    pub fn setValue(self: *Self, comptime T: type, pos: u64, value: T) void {
        const offset = pos * self.num_bytes_per_value;
        const ptr: *T = @ptrCast(@alignCast(&self.data[offset]));
        ptr.* = value;
        self.null_mask[pos] = false;
    }
    
    pub fn countNonNull(self: *const Self) u64 {
        var count: u64 = 0;
        const size = if (self.state) |s| s.getNumSelectedValues() else self.capacity;
        for (self.null_mask[0..size]) |is_null| {
            if (!is_null) count += 1;
        }
        return count;
    }
    
    pub fn setAllNull(self: *Self) void {
        @memset(self.null_mask, true);
    }
    
    pub fn setAllNonNull(self: *Self) void {
        @memset(self.null_mask, false);
    }
};

/// Result set - collection of vectors from query execution
pub const ResultSet = struct {
    allocator: std.mem.Allocator,
    data_chunks: std.ArrayList(*DataChunk),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .data_chunks = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.data_chunks.items) |chunk| {
            chunk.deinit();
            self.allocator.destroy(chunk);
        }
        self.data_chunks.deinit(self.allocator);
    }
    
    pub fn getDataChunk(self: *Self, idx: usize) ?*DataChunk {
        if (idx >= self.data_chunks.items.len) return null;
        return self.data_chunks.items[idx];
    }
    
    pub fn addDataChunk(self: *Self, chunk: *DataChunk) !void {
        try self.data_chunks.append(self.allocator, chunk);
    }
};

/// Data chunk - collection of value vectors
pub const DataChunk = struct {
    allocator: std.mem.Allocator,
    state: DataChunkState,
    value_vectors: std.ArrayList(*ValueVector),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .state = DataChunkState.init(allocator),
            .value_vectors = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.value_vectors.items) |vector| {
            vector.deinit();
            self.allocator.destroy(vector);
        }
        self.value_vectors.deinit(self.allocator);
    }
    
    pub fn addValueVector(self: *Self, vector: *ValueVector) !void {
        vector.setState(&self.state);
        try self.value_vectors.append(self.allocator, vector);
    }
    
    pub fn getValueVector(self: *Self, idx: usize) ?*ValueVector {
        if (idx >= self.value_vectors.items.len) return null;
        return self.value_vectors.items[idx];
    }
    
    pub fn getNumValueVectors(self: *const Self) usize {
        return self.value_vectors.items.len;
    }
};

/// Evaluator local state
pub const EvaluatorLocalState = struct {
    allocator: std.mem.Allocator,
    client_context: ?*anyopaque,
    
    pub fn init(allocator: std.mem.Allocator) EvaluatorLocalState {
        return .{
            .allocator = allocator,
            .client_context = null,
        };
    }
};

/// Expression Evaluator - base class for all expression evaluators
pub const ExpressionEvaluator = struct {
    allocator: std.mem.Allocator,
    
    /// Expression type
    expression_type: ExpressionType,
    
    /// Return type of expression
    return_type: LogicalType,
    
    /// Result vector
    result_vector: ?*ValueVector,
    
    /// Whether result is flat (single value)
    is_result_flat: bool,
    
    /// Child evaluators
    children: std.ArrayList(*ExpressionEvaluator),
    
    /// Local state
    local_state: EvaluatorLocalState,
    
    /// Expression string (for debugging)
    expression_string: []const u8,
    
    /// Virtual function table
    vtable: *const VTable,
    
    pub const VTable = struct {
        evaluate: *const fn (self: *ExpressionEvaluator) anyerror!void,
        evaluate_with_count: *const fn (self: *ExpressionEvaluator, count: u64) anyerror!void,
        select_internal: *const fn (self: *ExpressionEvaluator, sel_vector: *SelectionVector) bool,
        resolve_result_vector: *const fn (self: *ExpressionEvaluator, result_set: *ResultSet) anyerror!void,
        clone: *const fn (self: *ExpressionEvaluator) anyerror!*ExpressionEvaluator,
        destroy: *const fn (self: *ExpressionEvaluator) void,
    };
    
    const Self = @This();
    
    pub fn init(
        allocator: std.mem.Allocator,
        expression_type: ExpressionType,
        return_type: LogicalType,
        expression_string: []const u8,
        vtable: *const VTable,
    ) Self {
        return .{
            .allocator = allocator,
            .expression_type = expression_type,
            .return_type = return_type,
            .result_vector = null,
            .is_result_flat = true,
            .children = .{},
            .local_state = EvaluatorLocalState.init(allocator),
            .expression_string = expression_string,
            .vtable = vtable,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.children.deinit(self.allocator);
    }
    
    /// Initialize evaluator with result set and context
    pub fn initEvaluator(self: *Self, result_set: *ResultSet, client_context: ?*anyopaque) !void {
        self.local_state.client_context = client_context;
        
        // Initialize children first
        for (self.children.items) |child| {
            try child.initEvaluator(result_set, client_context);
        }
        
        // Resolve result vector
        try self.vtable.resolve_result_vector(self, result_set);
    }
    
    /// Evaluate expression
    pub fn evaluate(self: *Self) !void {
        try self.vtable.evaluate(self);
    }
    
    /// Evaluate with count (for aggregates)
    pub fn evaluateWithCount(self: *Self, count: u64) !void {
        try self.vtable.evaluate_with_count(self, count);
    }
    
    /// Select rows matching expression
    pub fn select(self: *Self, sel_vector: *SelectionVector, should_set_to_filtered: bool) bool {
        const result = self.vtable.select_internal(self, sel_vector);
        if (should_set_to_filtered and sel_vector.isUnfiltered()) {
            sel_vector.setToFiltered();
        }
        return result;
    }
    
    /// Resolve result state from children
    pub fn resolveResultStateFromChildren(self: *Self) void {
        if (self.result_vector) |rv| {
            if (rv.state != null) return;
        }
        
        // Check if any child is unflat
        for (self.children.items) |child| {
            if (!child.isResultFlat()) {
                self.is_result_flat = false;
                if (self.result_vector) |rv| {
                    if (child.result_vector) |crv| {
                        rv.setState(crv.state.?);
                    }
                }
                return;
            }
        }
        
        // All children are flat
        self.is_result_flat = true;
        if (self.result_vector) |rv| {
            var state = DataChunkState.init(self.allocator);
            state.initOriginalAndSelectedSize(1);
            state.setToFlat();
            rv.state = &state;
        }
    }
    
    /// Check if result is flat
    pub fn isResultFlat(self: *const Self) bool {
        return self.is_result_flat;
    }
    
    /// Add child evaluator
    pub fn addChild(self: *Self, child: *ExpressionEvaluator) !void {
        try self.children.append(self.allocator, child);
    }
    
    /// Clone the evaluator
    pub fn clone(self: *Self) !*ExpressionEvaluator {
        return self.vtable.clone(self);
    }
    
    /// Destroy the evaluator
    pub fn destroy(self: *Self) void {
        self.vtable.destroy(self);
    }
};

/// Literal Evaluator - evaluates constant values
pub const LiteralEvaluator = struct {
    base: ExpressionEvaluator,
    value: Value,
    
    const Self = @This();
    
    pub fn create(allocator: std.mem.Allocator, value: Value) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .base = ExpressionEvaluator.init(
                allocator,
                .LITERAL,
                value.value,
                "literal",
                &literal_vtable,
            ),
            .value = value,
        };
        return self;
    }
    
    fn evaluateImpl(base: *ExpressionEvaluator) !void {
        const self: *Self = @fieldParentPtr("base", base);
        if (base.result_vector) |rv| {
            // Set the literal value
            switch (self.value.value) {
                .INT64 => rv.setValue(i64, 0, self.value.int_value),
                .DOUBLE => rv.setValue(f64, 0, self.value.double_value),
                .BOOL => rv.setValue(bool, 0, self.value.bool_value),
                else => {},
            }
        }
    }
    
    fn evaluateWithCountImpl(base: *ExpressionEvaluator, count: u64) !void {
        _ = count;
        try evaluateImpl(base);
    }
    
    fn selectInternalImpl(base: *ExpressionEvaluator, sel_vector: *SelectionVector) bool {
        const self: *Self = @fieldParentPtr("base", base);
        // Literal select returns the boolean value for all positions
        if (self.value.value == .BOOL) {
            if (!self.value.bool_value) {
                sel_vector.setSelectedSize(0);
                return false;
            }
        }
        return true;
    }
    
    fn resolveResultVectorImpl(base: *ExpressionEvaluator, result_set: *ResultSet) !void {
        _ = result_set;
        // Create result vector for literal
        const rv = try base.allocator.create(ValueVector);
        rv.* = try ValueVector.init(base.allocator, base.return_type, 1);
        base.result_vector = rv;
        base.is_result_flat = true;
    }
    
    fn cloneImpl(base: *ExpressionEvaluator) !*ExpressionEvaluator {
        const self: *Self = @fieldParentPtr("base", base);
        const new = try Self.create(base.allocator, self.value);
        return &new.base;
    }
    
    fn destroyImpl(base: *ExpressionEvaluator) void {
        const self: *Self = @fieldParentPtr("base", base);
        if (base.result_vector) |rv| {
            rv.deinit();
            base.allocator.destroy(rv);
        }
        base.deinit();
        base.allocator.destroy(self);
    }
};

const literal_vtable = ExpressionEvaluator.VTable{
    .evaluate = LiteralEvaluator.evaluateImpl,
    .evaluate_with_count = LiteralEvaluator.evaluateWithCountImpl,
    .select_internal = LiteralEvaluator.selectInternalImpl,
    .resolve_result_vector = LiteralEvaluator.resolveResultVectorImpl,
    .clone = LiteralEvaluator.cloneImpl,
    .destroy = LiteralEvaluator.destroyImpl,
};

/// Reference Evaluator - evaluates column references
pub const ReferenceEvaluator = struct {
    base: ExpressionEvaluator,
    vector_pos: usize,
    chunk_pos: usize,
    
    const Self = @This();
    
    pub fn create(allocator: std.mem.Allocator, return_type: LogicalType, chunk_pos: usize, vector_pos: usize) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .base = ExpressionEvaluator.init(
                allocator,
                .REFERENCE,
                return_type,
                "reference",
                &reference_vtable,
            ),
            .vector_pos = vector_pos,
            .chunk_pos = chunk_pos,
        };
        return self;
    }
    
    fn evaluateImpl(base: *ExpressionEvaluator) !void {
        // Reference evaluation is a no-op - result vector points to input
        _ = base;
    }
    
    fn evaluateWithCountImpl(base: *ExpressionEvaluator, count: u64) !void {
        _ = base;
        _ = count;
    }
    
    fn selectInternalImpl(base: *ExpressionEvaluator, sel_vector: *SelectionVector) bool {
        _ = base;
        _ = sel_vector;
        return true;
    }
    
    fn resolveResultVectorImpl(base: *ExpressionEvaluator, result_set: *ResultSet) !void {
        const self: *Self = @fieldParentPtr("base", base);
        // Point to vector in result set
        if (result_set.getDataChunk(self.chunk_pos)) |chunk| {
            base.result_vector = chunk.getValueVector(self.vector_pos);
            if (base.result_vector) |rv| {
                base.is_result_flat = if (rv.state) |s| s.isFlat() else true;
            }
        }
    }
    
    fn cloneImpl(base: *ExpressionEvaluator) !*ExpressionEvaluator {
        const self: *Self = @fieldParentPtr("base", base);
        const new = try Self.create(base.allocator, base.return_type, self.chunk_pos, self.vector_pos);
        return &new.base;
    }
    
    fn destroyImpl(base: *ExpressionEvaluator) void {
        const self: *Self = @fieldParentPtr("base", base);
        base.deinit();
        base.allocator.destroy(self);
    }
};

const reference_vtable = ExpressionEvaluator.VTable{
    .evaluate = ReferenceEvaluator.evaluateImpl,
    .evaluate_with_count = ReferenceEvaluator.evaluateWithCountImpl,
    .select_internal = ReferenceEvaluator.selectInternalImpl,
    .resolve_result_vector = ReferenceEvaluator.resolveResultVectorImpl,
    .clone = ReferenceEvaluator.cloneImpl,
    .destroy = ReferenceEvaluator.destroyImpl,
};

/// Case Evaluator - CASE WHEN expression
pub const CaseEvaluator = struct {
    base: ExpressionEvaluator,
    
    /// Alternating condition/result pairs, with optional else
    when_evaluators: std.ArrayList(*ExpressionEvaluator),
    then_evaluators: std.ArrayList(*ExpressionEvaluator),
    else_evaluator: ?*ExpressionEvaluator,
    
    const Self = @This();
    
    pub fn create(allocator: std.mem.Allocator, return_type: LogicalType) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .base = ExpressionEvaluator.init(
                allocator,
                .CASE,
                return_type,
                "CASE",
                &case_vtable,
            ),
            .when_evaluators = .{},
            .then_evaluators = .{},
            .else_evaluator = null,
        };
        return self;
    }
    
    pub fn addWhenThen(self: *Self, when_eval: *ExpressionEvaluator, then_eval: *ExpressionEvaluator) !void {
        try self.when_evaluators.append(self.allocator, when_eval);
        try self.then_evaluators.append(self.allocator, then_eval);
    }
    
    pub fn setElse(self: *Self, else_eval: *ExpressionEvaluator) void {
        self.else_evaluator = else_eval;
    }
    
    fn evaluateImpl(base: *ExpressionEvaluator) !void {
        const self: *Self = @fieldParentPtr("base", base);
        const result_vector = base.result_vector orelse return;
        
        // Evaluate each WHEN clause
        for (self.when_evaluators.items, 0..) |when_eval, i| {
            try when_eval.evaluate();
            
            // Check condition
            if (when_eval.result_vector) |when_rv| {
                if (!when_rv.isNull(0)) {
                    if (when_rv.getValue(bool, 0)) |cond| {
                        if (cond) {
                            // Evaluate THEN
                            const then_eval = self.then_evaluators.items[i];
                            try then_eval.evaluate();
                            if (then_eval.result_vector) |then_rv| {
                                // Copy result
                                // _ = result_vector;
                                _ = then_rv;
                                // TODO: Copy value to result vector
                            }
                            return;
                        }
                    }
                }
            }
        }
        
        // No condition matched - evaluate ELSE
        if (self.else_evaluator) |else_eval| {
            try else_eval.evaluate();
            // TODO: Copy else result
        } else {
            // Set to null
            result_vector.setNull(0, true);
        }
    }
    
    fn evaluateWithCountImpl(base: *ExpressionEvaluator, count: u64) !void {
        _ = count;
        try evaluateImpl(base);
    }
    
    fn selectInternalImpl(base: *ExpressionEvaluator, sel_vector: *SelectionVector) bool {
        _ = base;
        _ = sel_vector;
        return true;
    }
    
    fn resolveResultVectorImpl(base: *ExpressionEvaluator, result_set: *ResultSet) !void {
        _ = result_set;
        const rv = try base.allocator.create(ValueVector);
        rv.* = try ValueVector.init(base.allocator, base.return_type, 2048);
        base.result_vector = rv;
    }
    
    fn cloneImpl(base: *ExpressionEvaluator) !*ExpressionEvaluator {
        const new = try Self.create(base.allocator, base.return_type);
        return &new.base;
    }
    
    fn destroyImpl(base: *ExpressionEvaluator) void {
        const self: *Self = @fieldParentPtr("base", base);
        self.when_evaluators.deinit(self.allocator);
        self.then_evaluators.deinit(self.allocator);
        if (base.result_vector) |rv| {
            rv.deinit();
            base.allocator.destroy(rv);
        }
        base.deinit();
        base.allocator.destroy(self);
    }
};

const case_vtable = ExpressionEvaluator.VTable{
    .evaluate = CaseEvaluator.evaluateImpl,
    .evaluate_with_count = CaseEvaluator.evaluateWithCountImpl,
    .select_internal = CaseEvaluator.selectInternalImpl,
    .resolve_result_vector = CaseEvaluator.resolveResultVectorImpl,
    .clone = CaseEvaluator.cloneImpl,
    .destroy = CaseEvaluator.destroyImpl,
};

// ============================================================================
// Tests
// ============================================================================

test "selection vector" {
    const allocator = std.testing.allocator;
    
    var sv = try SelectionVector.init(allocator);
    defer sv.deinit();
    
    try std.testing.expect(sv.isUnfiltered());
    try std.testing.expectEqual(@as(u64, 2048), sv.getSelectedSize());
    
    sv.setToFiltered();
    try std.testing.expect(!sv.isUnfiltered());
    
    sv.setSelectedSize(100);
    try std.testing.expectEqual(@as(u64, 100), sv.getSelectedSize());
}

test "value vector" {
    const allocator = std.testing.allocator;
    
    var vv = try ValueVector.init(allocator, .INT64, 10);
    defer vv.deinit();
    
    vv.setValue(i64, 0, 42);
    vv.setValue(i64, 1, 100);
    vv.setNull(2, true);
    
    try std.testing.expectEqual(@as(?i64, 42), vv.getValue(i64, 0));
    try std.testing.expectEqual(@as(?i64, 100), vv.getValue(i64, 1));
    try std.testing.expectEqual(@as(?i64, null), vv.getValue(i64, 2));
    
    try std.testing.expect(!vv.isNull(0));
    try std.testing.expect(vv.isNull(2));
}

test "data chunk state" {
    const allocator = std.testing.allocator;
    
    var state = DataChunkState.init(allocator);
    
    state.initOriginalAndSelectedSize(100);
    try std.testing.expectEqual(@as(u64, 100), state.getNumSelectedValues());
    
    state.setToFlat();
    try std.testing.expect(state.isFlat());
    
    state.setToUnflat();
    try std.testing.expect(!state.isFlat());
}

test "literal evaluator" {
    // const allocator = std.testing.allocator;
    
    // const value = Value{
            // .value = .INT64,
    // .int_value = 42,
    // .bool_value = false,
    // .double_value = 0.0,
    // .string_value = "",

    
    // // // const eval = try LiteralEvaluator.create(allocator, value);
    // // // defer eval.base.destroy();
    
    // // // try std.testing.expectEqual(ExpressionType.LITERAL, eval.base.expression_type);
    // // // try std.testing.expectEqual(LogicalType.INT64, eval.base.return_type);
}