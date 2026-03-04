//! Physical Operator - Base Query Execution Operator
//!
//! Converted from: kuzu/src/processor/operator/physical_operator.cpp
//!
//! Purpose:
//! Defines the base interface for all physical operators in the
//! query execution engine. Uses Volcano-style iterator model.
//!
//! Architecture:
//! ```
//! PhysicalOperator (base)
//!   ├── init()      // Initialize operator state
//!   ├── getNext()   // Get next tuple batch
//!   └── close()     // Release resources
//!
//! Operator Tree:
//!   ResultCollector
//!       ↑
//!   Projection
//!       ↑
//!     Filter
//!       ↑
//!   TableScan
//! ```

const std = @import("std");
const common = @import("../common/common.zig");

/// Operator type enumeration
pub const PhysicalOperatorType = enum {
    // Scan operators
    TABLE_SCAN,
    INDEX_SCAN,
    NODE_SCAN,
    REL_SCAN,
    
    // Filter/Selection
    FILTER,
    
    // Projection
    PROJECTION,
    FLATTEN,
    
    // Join operators
    HASH_JOIN,
    INDEX_NESTED_LOOP_JOIN,
    CROSS_PRODUCT,
    INTERSECT,
    
    // Aggregation
    AGGREGATE,
    HASH_AGGREGATE,
    ORDER_BY,
    TOP_K,
    
    // Set operations
    UNION,
    UNION_ALL,
    
    // Limit/Skip
    LIMIT,
    SKIP,
    
    // Path traversal
    RECURSIVE_EXTEND,
    PATH_PROPERTY_PROBE,
    
    // DML
    INSERT,
    DELETE,
    UPDATE,
    MERGE,
    
    // DDL
    CREATE_TABLE,
    DROP_TABLE,
    ALTER_TABLE,
    CREATE_INDEX,
    
    // Result
    RESULT_COLLECTOR,
    EMPTY_RESULT,
    
    // Utility
    UNWIND,
    TRANSACTION,
    PROFILE,
    SEMI_MASKER,
    MULTIPLICITY_REDUCER,
};

/// Operator state
pub const OperatorState = enum {
    UNINITIALIZED,
    INITIALIZED,
    EXECUTING,
    FINISHED,
    CLOSED,
};

/// Result state from getNext
pub const ResultState = enum {
    HAS_MORE,       // More tuples available
    NO_MORE_TUPLES, // No more tuples
    ERROR,          // Error occurred
};

/// Operator metrics for profiling
pub const OperatorMetrics = struct {
    execution_time_ns: u64,
    num_output_tuples: u64,
    num_input_tuples: u64,
    memory_used: u64,
    
    pub fn init() OperatorMetrics {
        return .{
            .execution_time_ns = 0,
            .num_output_tuples = 0,
            .num_input_tuples = 0,
            .memory_used = 0,
        };
    }
    
    pub fn addOutputTuples(self: *OperatorMetrics, count: u64) void {
        self.num_output_tuples += count;
    }
    
    pub fn addInputTuples(self: *OperatorMetrics, count: u64) void {
        self.num_input_tuples += count;
    }
};

/// Data chunk - batch of tuples
pub const DataChunk = struct {
    allocator: std.mem.Allocator,
    columns: std.ArrayList(ColumnVector),
    num_tuples: u64,
    capacity: u64,
    
    const Self = @This();
    const DEFAULT_CAPACITY: u64 = 2048;
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .columns = std.ArrayList(ColumnVector).init(allocator),
            .num_tuples = 0,
            .capacity = DEFAULT_CAPACITY,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.columns.items) |*col| {
            col.deinit();
        }
        self.columns.deinit();
    }
    
    pub fn addColumn(self: *Self, data_type: common.LogicalType) !*ColumnVector {
        const col = ColumnVector.init(self.allocator, data_type);
        try self.columns.append(col);
        return &self.columns.items[self.columns.items.len - 1];
    }
    
    pub fn getColumn(self: *Self, idx: usize) ?*ColumnVector {
        if (idx >= self.columns.items.len) return null;
        return &self.columns.items[idx];
    }
    
    pub fn getNumColumns(self: *const Self) usize {
        return self.columns.items.len;
    }
    
    pub fn reset(self: *Self) void {
        self.num_tuples = 0;
        for (self.columns.items) |*col| {
            col.reset();
        }
    }
};

/// Column vector - single column of values
pub const ColumnVector = struct {
    allocator: std.mem.Allocator,
    data_type: common.LogicalType,
    data: std.ArrayList(u8),
    null_mask: std.ArrayList(bool),
    num_values: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, data_type: common.LogicalType) Self {
        return .{
            .allocator = allocator,
            .data_type = data_type,
            .data = std.ArrayList(u8).init(allocator),
            .null_mask = std.ArrayList(bool).init(allocator),
            .num_values = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.data.deinit();
        self.null_mask.deinit();
    }
    
    pub fn appendInt64(self: *Self, value: i64, is_null: bool) !void {
        try self.data.appendSlice(std.mem.asBytes(&value));
        try self.null_mask.append(is_null);
        self.num_values += 1;
    }
    
    pub fn appendFloat64(self: *Self, value: f64, is_null: bool) !void {
        try self.data.appendSlice(std.mem.asBytes(&value));
        try self.null_mask.append(is_null);
        self.num_values += 1;
    }
    
    pub fn appendBool(self: *Self, value: bool, is_null: bool) !void {
        try self.data.append(@intFromBool(value));
        try self.null_mask.append(is_null);
        self.num_values += 1;
    }
    
    pub fn getInt64(self: *const Self, idx: u64) ?i64 {
        if (idx >= self.num_values) return null;
        if (self.null_mask.items[idx]) return null;
        
        const offset = idx * 8;
        if (offset + 8 > self.data.items.len) return null;
        
        return std.mem.bytesAsValue(i64, self.data.items[offset..][0..8]).*;
    }
    
    pub fn isNull(self: *const Self, idx: u64) bool {
        if (idx >= self.null_mask.items.len) return true;
        return self.null_mask.items[idx];
    }
    
    pub fn reset(self: *Self) void {
        self.data.clearRetainingCapacity();
        self.null_mask.clearRetainingCapacity();
        self.num_values = 0;
    }
};

/// Physical operator interface using vtable pattern
pub const PhysicalOperator = struct {
    vtable: *const VTable,
    operator_type: PhysicalOperatorType,
    state: OperatorState,
    metrics: OperatorMetrics,
    children: std.ArrayList(*PhysicalOperator),
    allocator: std.mem.Allocator,
    
    pub const VTable = struct {
        initFn: *const fn (*PhysicalOperator) anyerror!void,
        getNextFn: *const fn (*PhysicalOperator, *DataChunk) anyerror!ResultState,
        closeFn: *const fn (*PhysicalOperator) void,
    };
    
    const Self = @This();
    
    pub fn init(
        allocator: std.mem.Allocator,
        operator_type: PhysicalOperatorType,
        vtable: *const VTable,
    ) Self {
        return .{
            .vtable = vtable,
            .operator_type = operator_type,
            .state = .UNINITIALIZED,
            .metrics = OperatorMetrics.init(),
            .children = std.ArrayList(*PhysicalOperator).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.children.deinit();
    }
    
    pub fn initOp(self: *Self) !void {
        try self.vtable.initFn(self);
        self.state = .INITIALIZED;
    }
    
    pub fn getNext(self: *Self, chunk: *DataChunk) !ResultState {
        self.state = .EXECUTING;
        return self.vtable.getNextFn(self, chunk);
    }
    
    pub fn close(self: *Self) void {
        self.vtable.closeFn(self);
        self.state = .CLOSED;
    }
    
    pub fn addChild(self: *Self, child: *PhysicalOperator) !void {
        try self.children.append(child);
    }
    
    pub fn getChild(self: *Self, idx: usize) ?*PhysicalOperator {
        if (idx >= self.children.items.len) return null;
        return self.children.items[idx];
    }
};

/// Sink operator - consumes all input
pub const SinkOperator = struct {
    base: PhysicalOperator,
    result_set: ?*DataChunk,
    
    const vtable = PhysicalOperator.VTable{
        .initFn = sinkInit,
        .getNextFn = sinkGetNext,
        .closeFn = sinkClose,
    };
    
    pub fn create(allocator: std.mem.Allocator) !*SinkOperator {
        const self = try allocator.create(SinkOperator);
        self.* = .{
            .base = PhysicalOperator.init(allocator, .RESULT_COLLECTOR, &vtable),
            .result_set = null,
        };
        return self;
    }
    
    fn sinkInit(base: *PhysicalOperator) !void {
        _ = base;
    }
    
    fn sinkGetNext(base: *PhysicalOperator, chunk: *DataChunk) !ResultState {
        const self: *SinkOperator = @fieldParentPtr("base", base);
        
        // Get from child
        if (base.children.items.len > 0) {
            const child = base.children.items[0];
            const result = try child.getNext(chunk);
            
            if (result == .HAS_MORE) {
                self.base.metrics.addInputTuples(chunk.num_tuples);
            }
            
            return result;
        }
        
        return .NO_MORE_TUPLES;
    }
    
    fn sinkClose(base: *PhysicalOperator) void {
        _ = base;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "data chunk" {
    const allocator = std.testing.allocator;
    
    var chunk = DataChunk.init(allocator);
    defer chunk.deinit();
    
    const col = try chunk.addColumn(.INT64);
    try col.appendInt64(42, false);
    try col.appendInt64(0, true); // null
    
    try std.testing.expectEqual(@as(u64, 2), col.num_values);
    try std.testing.expectEqual(@as(i64, 42), col.getInt64(0).?);
    try std.testing.expect(col.isNull(1));
}

test "column vector" {
    const allocator = std.testing.allocator;
    
    var vec = ColumnVector.init(allocator, .INT64);
    defer vec.deinit();
    
    try vec.appendInt64(100, false);
    try vec.appendInt64(200, false);
    
    try std.testing.expectEqual(@as(i64, 100), vec.getInt64(0).?);
    try std.testing.expectEqual(@as(i64, 200), vec.getInt64(1).?);
}

test "operator metrics" {
    var metrics = OperatorMetrics.init();
    
    metrics.addOutputTuples(100);
    metrics.addInputTuples(150);
    
    try std.testing.expectEqual(@as(u64, 100), metrics.num_output_tuples);
    try std.testing.expectEqual(@as(u64, 150), metrics.num_input_tuples);
}