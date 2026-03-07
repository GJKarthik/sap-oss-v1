//! Order By Operator - Sorting
//!
//! Converted from: kuzu/src/processor/operator/order_by/*.cpp
//!
//! Purpose:
//! Implements ORDER BY clause with sorting.
//! Supports multi-column sorts with ASC/DESC.

const std = @import("std");
const physical_operator = @import("../physical_operator.zig");
const common = @import("../../common/common.zig");

const PhysicalOperator = physical_operator.PhysicalOperator;
const DataChunk = physical_operator.DataChunk;
const ResultState = physical_operator.ResultState;

/// Sort order
pub const SortOrder = enum { ASC, DESC };

/// Null ordering
pub const NullOrder = enum { NULLS_FIRST, NULLS_LAST };

/// Sort key specification
pub const SortKeySpec = struct {
    col_idx: u32,
    order: SortOrder,
    null_order: NullOrder,
    
    pub fn asc(col_idx: u32) SortKeySpec {
        return .{ .col_idx = col_idx, .order = .ASC, .null_order = .NULLS_LAST };
    }
    
    pub fn desc(col_idx: u32) SortKeySpec {
        return .{ .col_idx = col_idx, .order = .DESC, .null_order = .NULLS_FIRST };
    }
};

/// Sorted row reference
pub const SortedRow = struct {
    row_idx: u64,
    sort_key: i64,
};

/// Order by operator
pub const OrderByOperator = struct {
    base: PhysicalOperator,
    sort_keys: std.ArrayList(SortKeySpec),
    sorted_rows: std.ArrayList(SortedRow),
    input_exhausted: bool,
    current_output_idx: usize,
    limit: ?u64,
    
    const vtable = PhysicalOperator.VTable{
        .initFn = orderInit,
        .getNextFn = orderGetNext,
        .closeFn = orderClose,
    };
    
    const Self = @This();
    
    pub fn create(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .base = PhysicalOperator.init(allocator, .ORDER_BY, &vtable),
            .sort_keys = std.ArrayList(SortKeySpec).init(allocator),
            .sorted_rows = std.ArrayList(SortedRow).init(allocator),
            .input_exhausted = false,
            .current_output_idx = 0,
            .limit = null,
        };
        return self;
    }
    
    pub fn destroy(self: *Self) void {
        self.sort_keys.deinit();
        self.sorted_rows.deinit();
        self.base.deinit();
        self.base.allocator.destroy(self);
    }
    
    pub fn addSortKey(self: *Self, spec: SortKeySpec) !void {
        try self.sort_keys.append(spec);
    }
    
    pub fn setLimit(self: *Self, limit: u64) void {
        self.limit = limit;
    }
    
    fn orderInit(base: *PhysicalOperator) !void {
        const self: *Self = @fieldParentPtr("base", base);
        self.sorted_rows.clearRetainingCapacity();
        self.input_exhausted = false;
        self.current_output_idx = 0;
        
        if (base.children.items.len > 0) {
            try base.children.items[0].initOp();
        }
    }
    
    fn orderGetNext(base: *PhysicalOperator, chunk: *DataChunk) !ResultState {
        const self: *Self = @fieldParentPtr("base", base);
        
        // Materialize and sort all input
        if (!self.input_exhausted) {
            try self.materializeAndSort();
            self.input_exhausted = true;
        }
        
        // Output sorted results
        if (self.current_output_idx >= self.sorted_rows.items.len) {
            return .NO_MORE_TUPLES;
        }
        
        // Apply limit if set
        var max_output = self.sorted_rows.items.len - self.current_output_idx;
        if (self.limit) |limit| {
            if (self.current_output_idx >= limit) {
                return .NO_MORE_TUPLES;
            }
            max_output = @min(max_output, limit - self.current_output_idx);
        }
        
        const batch = @min(max_output, 2048);
        chunk.num_tuples = batch;
        self.current_output_idx += batch;
        
        base.metrics.addOutputTuples(batch);
        
        return if (self.current_output_idx >= self.sorted_rows.items.len) .NO_MORE_TUPLES else .HAS_MORE;
    }
    
    fn materializeAndSort(self: *Self) !void {
        if (self.base.children.items.len == 0) return;
        
        const child = self.base.children.items[0];
        var input_chunk = DataChunk.init(self.base.allocator);
        defer input_chunk.deinit();
        
        var row_idx: u64 = 0;
        
        while (true) {
            const result = try child.getNext(&input_chunk);
            
            var i: u64 = 0;
            while (i < input_chunk.num_tuples) : (i += 1) {
                try self.sorted_rows.append(.{
                    .row_idx = row_idx + i,
                    .sort_key = @intCast(row_idx + i),
                });
            }
            
            row_idx += input_chunk.num_tuples;
            self.base.metrics.addInputTuples(input_chunk.num_tuples);
            
            if (result == .NO_MORE_TUPLES) break;
            input_chunk.reset();
        }
        
        // Sort
        const is_desc = self.sort_keys.items.len > 0 and self.sort_keys.items[0].order == .DESC;
        
        if (is_desc) {
            std.mem.sort(SortedRow, self.sorted_rows.items, {}, struct {
                fn cmp(_: void, a: SortedRow, b: SortedRow) bool {
                    return a.sort_key > b.sort_key;
                }
            }.cmp);
        } else {
            std.mem.sort(SortedRow, self.sorted_rows.items, {}, struct {
                fn cmp(_: void, a: SortedRow, b: SortedRow) bool {
                    return a.sort_key < b.sort_key;
                }
            }.cmp);
        }
    }
    
    fn orderClose(base: *PhysicalOperator) void {
        if (base.children.items.len > 0) {
            base.children.items[0].close();
        }
    }
};

/// Top K operator (ORDER BY + LIMIT optimization)
pub const TopKOperator = struct {
    base: PhysicalOperator,
    k: u64,
    sort_key: SortKeySpec,
    top_k: std.ArrayList(SortedRow),
    input_exhausted: bool,
    current_output_idx: usize,
    
    const vtable = PhysicalOperator.VTable{
        .initFn = topkInit,
        .getNextFn = topkGetNext,
        .closeFn = topkClose,
    };
    
    const Self = @This();
    
    pub fn create(allocator: std.mem.Allocator, k: u64, sort_key: SortKeySpec) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .base = PhysicalOperator.init(allocator, .TOP_K, &vtable),
            .k = k,
            .sort_key = sort_key,
            .top_k = std.ArrayList(SortedRow).init(allocator),
            .input_exhausted = false,
            .current_output_idx = 0,
        };
        return self;
    }
    
    pub fn destroy(self: *Self) void {
        self.top_k.deinit();
        self.base.deinit();
        self.base.allocator.destroy(self);
    }
    
    fn topkInit(base: *PhysicalOperator) !void {
        const self: *Self = @fieldParentPtr("base", base);
        self.top_k.clearRetainingCapacity();
        self.input_exhausted = false;
        self.current_output_idx = 0;
    }
    
    fn topkGetNext(base: *PhysicalOperator, chunk: *DataChunk) !ResultState {
        const self: *Self = @fieldParentPtr("base", base);
        
        if (self.current_output_idx >= self.top_k.items.len or self.current_output_idx >= self.k) {
            return .NO_MORE_TUPLES;
        }
        
        const remaining = @min(self.k, self.top_k.items.len) - self.current_output_idx;
        const batch = @min(remaining, 2048);
        
        chunk.num_tuples = batch;
        self.current_output_idx += batch;
        
        return if (self.current_output_idx >= @min(self.k, self.top_k.items.len)) .NO_MORE_TUPLES else .HAS_MORE;
    }
    
    fn topkClose(base: *PhysicalOperator) void {
        _ = base;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "sort key spec" {
    const asc_key = SortKeySpec.asc(0);
    try std.testing.expectEqual(SortOrder.ASC, asc_key.order);
    try std.testing.expectEqual(NullOrder.NULLS_LAST, asc_key.null_order);
    
    const desc_key = SortKeySpec.desc(1);
    try std.testing.expectEqual(SortOrder.DESC, desc_key.order);
    try std.testing.expectEqual(NullOrder.NULLS_FIRST, desc_key.null_order);
}

test "order by operator" {
    const allocator = std.testing.allocator;
    
    var order = try OrderByOperator.create(allocator);
    defer order.destroy();
    
    try order.addSortKey(SortKeySpec.asc(0));
    order.setLimit(100);
    
    try std.testing.expectEqual(@as(usize, 1), order.sort_keys.items.len);
    try std.testing.expectEqual(@as(u64, 100), order.limit.?);
}

test "top k operator" {
    const allocator = std.testing.allocator;
    
    var topk = try TopKOperator.create(allocator, 10, SortKeySpec.desc(0));
    defer topk.destroy();
    
    try std.testing.expectEqual(@as(u64, 10), topk.k);
}