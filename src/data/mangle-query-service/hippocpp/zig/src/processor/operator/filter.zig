//! Filter Operators - Row filtering and selection
//!
//! Purpose:
//! Provides operators for filtering rows based on predicates,
//! supporting various filter conditions and optimizations.

const std = @import("std");

// ============================================================================
// Filter Type
// ============================================================================

pub const FilterType = enum {
    SIMPLE,         // Single predicate
    AND,            // Conjunction of predicates
    OR,             // Disjunction of predicates
    NOT,            // Negation
    IN_LIST,        // IN (value, value, ...)
    BETWEEN,        // BETWEEN low AND high
    IS_NULL,        // IS NULL / IS NOT NULL
    LIKE,           // String pattern matching
};

// ============================================================================
// Comparison Operator
// ============================================================================

pub const CompareOp = enum {
    EQ,     // =
    NE,     // <>
    LT,     // <
    LE,     // <=
    GT,     // >
    GE,     // >=
    
    pub fn evaluate(self: CompareOp, left: i64, right: i64) bool {
        return switch (self) {
            .EQ => left == right,
            .NE => left != right,
            .LT => left < right,
            .LE => left <= right,
            .GT => left > right,
            .GE => left >= right,
        };
    }
    
    pub fn evaluateFloat(self: CompareOp, left: f64, right: f64) bool {
        return switch (self) {
            .EQ => left == right,
            .NE => left != right,
            .LT => left < right,
            .LE => left <= right,
            .GT => left > right,
            .GE => left >= right,
        };
    }
};

// ============================================================================
// Filter Predicate
// ============================================================================

pub const FilterPredicate = struct {
    column_idx: u32,
    op: CompareOp,
    value: i64,
    is_null_check: bool = false,
    
    pub fn init(column_idx: u32, op: CompareOp, value: i64) FilterPredicate {
        return .{ .column_idx = column_idx, .op = op, .value = value };
    }
    
    pub fn evaluate(self: *const FilterPredicate, row_value: i64) bool {
        return self.op.evaluate(row_value, self.value);
    }
};

// ============================================================================
// Filter Operator
// ============================================================================

pub const FilterOperator = struct {
    allocator: std.mem.Allocator,
    predicates: std.ArrayList(FilterPredicate),
    filter_type: FilterType = .AND,
    
    // Statistics
    rows_input: u64 = 0,
    rows_output: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator) FilterOperator {
        return .{
            .allocator = allocator,
            .predicates = std.ArrayList(FilterPredicate).init(allocator),
        };
    }
    
    pub fn deinit(self: *FilterOperator) void {
        self.predicates.deinit();
    }
    
    pub fn addPredicate(self: *FilterOperator, predicate: FilterPredicate) !void {
        try self.predicates.append(predicate);
    }
    
    pub fn evaluate(self: *FilterOperator, row_values: []const i64) bool {
        self.rows_input += 1;
        
        const result = switch (self.filter_type) {
            .AND => self.evaluateAnd(row_values),
            .OR => self.evaluateOr(row_values),
            else => self.evaluateAnd(row_values),
        };
        
        if (result) self.rows_output += 1;
        return result;
    }
    
    fn evaluateAnd(self: *const FilterOperator, row_values: []const i64) bool {
        for (self.predicates.items) |pred| {
            if (pred.column_idx >= row_values.len) return false;
            if (!pred.evaluate(row_values[pred.column_idx])) return false;
        }
        return true;
    }
    
    fn evaluateOr(self: *const FilterOperator, row_values: []const i64) bool {
        if (self.predicates.items.len == 0) return true;
        for (self.predicates.items) |pred| {
            if (pred.column_idx < row_values.len and pred.evaluate(row_values[pred.column_idx])) {
                return true;
            }
        }
        return false;
    }
    
    pub fn getSelectivity(self: *const FilterOperator) f64 {
        if (self.rows_input == 0) return 1.0;
        return @as(f64, @floatFromInt(self.rows_output)) / @as(f64, @floatFromInt(self.rows_input));
    }
    
    pub fn getStats(self: *const FilterOperator) FilterStats {
        return .{
            .rows_input = self.rows_input,
            .rows_output = self.rows_output,
            .selectivity = self.getSelectivity(),
        };
    }
};

pub const FilterStats = struct {
    rows_input: u64,
    rows_output: u64,
    selectivity: f64,
};

// ============================================================================
// Between Filter
// ============================================================================

pub const BetweenFilter = struct {
    column_idx: u32,
    low: i64,
    high: i64,
    inclusive: bool = true,
    
    pub fn init(column_idx: u32, low: i64, high: i64) BetweenFilter {
        return .{ .column_idx = column_idx, .low = low, .high = high };
    }
    
    pub fn evaluate(self: *const BetweenFilter, value: i64) bool {
        if (self.inclusive) {
            return value >= self.low and value <= self.high;
        } else {
            return value > self.low and value < self.high;
        }
    }
};

// ============================================================================
// In List Filter
// ============================================================================

pub const InListFilter = struct {
    allocator: std.mem.Allocator,
    column_idx: u32,
    values: std.ArrayList(i64),
    
    pub fn init(allocator: std.mem.Allocator, column_idx: u32) InListFilter {
        return .{
            .allocator = allocator,
            .column_idx = column_idx,
            .values = std.ArrayList(i64).init(allocator),
        };
    }
    
    pub fn deinit(self: *InListFilter) void {
        self.values.deinit();
    }
    
    pub fn addValue(self: *InListFilter, value: i64) !void {
        try self.values.append(value);
    }
    
    pub fn evaluate(self: *const InListFilter, value: i64) bool {
        for (self.values.items) |v| {
            if (v == value) return true;
        }
        return false;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "compare op" {
    try std.testing.expect(CompareOp.EQ.evaluate(5, 5));
    try std.testing.expect(!CompareOp.EQ.evaluate(5, 6));
    try std.testing.expect(CompareOp.LT.evaluate(5, 6));
    try std.testing.expect(CompareOp.GE.evaluate(5, 5));
}

test "filter predicate" {
    const pred = FilterPredicate.init(0, .GT, 10);
    try std.testing.expect(pred.evaluate(15));
    try std.testing.expect(!pred.evaluate(5));
}

test "filter operator and" {
    const allocator = std.testing.allocator;
    
    var filter = FilterOperator.init(allocator);
    defer filter.deinit();
    
    try filter.addPredicate(FilterPredicate.init(0, .GT, 5));
    try filter.addPredicate(FilterPredicate.init(1, .LT, 20));
    
    try std.testing.expect(filter.evaluate(&[_]i64{ 10, 15 }));
    try std.testing.expect(!filter.evaluate(&[_]i64{ 3, 15 }));
    try std.testing.expect(!filter.evaluate(&[_]i64{ 10, 25 }));
}

test "filter operator or" {
    const allocator = std.testing.allocator;
    
    var filter = FilterOperator.init(allocator);
    defer filter.deinit();
    filter.filter_type = .OR;
    
    try filter.addPredicate(FilterPredicate.init(0, .EQ, 5));
    try filter.addPredicate(FilterPredicate.init(0, .EQ, 10));
    
    try std.testing.expect(filter.evaluate(&[_]i64{5}));
    try std.testing.expect(filter.evaluate(&[_]i64{10}));
    try std.testing.expect(!filter.evaluate(&[_]i64{7}));
}

test "between filter" {
    const filter = BetweenFilter.init(0, 10, 20);
    try std.testing.expect(filter.evaluate(10));
    try std.testing.expect(filter.evaluate(15));
    try std.testing.expect(filter.evaluate(20));
    try std.testing.expect(!filter.evaluate(5));
    try std.testing.expect(!filter.evaluate(25));
}

test "in list filter" {
    const allocator = std.testing.allocator;
    
    var filter = InListFilter.init(allocator, 0);
    defer filter.deinit();
    
    try filter.addValue(1);
    try filter.addValue(5);
    try filter.addValue(10);
    
    try std.testing.expect(filter.evaluate(1));
    try std.testing.expect(filter.evaluate(5));
    try std.testing.expect(!filter.evaluate(7));
}