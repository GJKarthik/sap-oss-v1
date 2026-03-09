//! Predicate - Query Predicate Evaluation
//!
//! Converted from: kuzu/src/storage/predicate/*.cpp
//!
//! Purpose:
//! Implements predicates for filtering during scans.
//! Supports column, null, and constant predicates for zone map filtering.

const std = @import("std");
const common = @import("common");

const LogicalType = common.LogicalType;

/// Comparison type
pub const ComparisonType = enum {
    EQUAL,
    NOT_EQUAL,
    LESS_THAN,
    LESS_THAN_EQUAL,
    GREATER_THAN,
    GREATER_THAN_EQUAL,
    IS_NULL,
    IS_NOT_NULL,
    IN,
    NOT_IN,
};

/// Predicate result
pub const PredicateResult = enum {
    TRUE,        // All values pass
    FALSE,       // No values pass
    MAYBE,       // Some values might pass
};

/// Base predicate interface
pub const Predicate = struct {
    predicate_type: PredicateType,
    
    pub const PredicateType = enum {
        COLUMN,
        NULL,
        CONSTANT,
        AND,
        OR,
        NOT,
    };
    
    pub fn init(predicate_type: PredicateType) Predicate {
        return .{ .predicate_type = predicate_type };
    }
};

/// Column predicate - compares column value to constant
pub const ColumnPredicate = struct {
    base: Predicate,
    column_idx: u32,
    comparison: ComparisonType,
    value: PredicateValue,
    data_type: LogicalType,
    
    const Self = @This();
    
    pub fn init(column_idx: u32, comparison: ComparisonType, data_type: LogicalType) Self {
        return .{
            .base = Predicate.init(.COLUMN),
            .column_idx = column_idx,
            .comparison = comparison,
            .value = PredicateValue.init(),
            .data_type = data_type,
        };
    }
    
    pub fn setIntValue(self: *Self, value: i64) void {
        self.value.int_value = value;
        self.value.value_type = .INT;
    }
    
    pub fn setFloatValue(self: *Self, value: f64) void {
        self.value.float_value = value;
        self.value.value_type = .FLOAT;
    }
    
    pub fn setBoolValue(self: *Self, value: bool) void {
        self.value.bool_value = value;
        self.value.value_type = .BOOL;
    }
    
    /// Evaluate against zone map (min/max)
    pub fn evaluateZoneMap(self: *const Self, min: i64, max: i64) PredicateResult {
        const val = self.value.int_value;
        
        return switch (self.comparison) {
            .EQUAL => blk: {
                if (val < min or val > max) break :blk .FALSE;
                if (min == max and min == val) break :blk .TRUE;
                break :blk .MAYBE;
            },
            .NOT_EQUAL => blk: {
                if (min == max and min == val) break :blk .FALSE;
                if (val < min or val > max) break :blk .TRUE;
                break :blk .MAYBE;
            },
            .LESS_THAN => blk: {
                if (min >= val) break :blk .FALSE;
                if (max < val) break :blk .TRUE;
                break :blk .MAYBE;
            },
            .LESS_THAN_EQUAL => blk: {
                if (min > val) break :blk .FALSE;
                if (max <= val) break :blk .TRUE;
                break :blk .MAYBE;
            },
            .GREATER_THAN => blk: {
                if (max <= val) break :blk .FALSE;
                if (min > val) break :blk .TRUE;
                break :blk .MAYBE;
            },
            .GREATER_THAN_EQUAL => blk: {
                if (max < val) break :blk .FALSE;
                if (min >= val) break :blk .TRUE;
                break :blk .MAYBE;
            },
            else => .MAYBE,
        };
    }
    
    /// Evaluate single value
    pub fn evaluate(self: *const Self, value: i64) bool {
        const cmp_val = self.value.int_value;
        
        return switch (self.comparison) {
            .EQUAL => value == cmp_val,
            .NOT_EQUAL => value != cmp_val,
            .LESS_THAN => value < cmp_val,
            .LESS_THAN_EQUAL => value <= cmp_val,
            .GREATER_THAN => value > cmp_val,
            .GREATER_THAN_EQUAL => value >= cmp_val,
            else => true,
        };
    }
};

/// Null predicate - checks for NULL values
pub const NullPredicate = struct {
    base: Predicate,
    column_idx: u32,
    is_null: bool,
    
    const Self = @This();
    
    pub fn init(column_idx: u32, is_null: bool) Self {
        return .{
            .base = Predicate.init(.NULL),
            .column_idx = column_idx,
            .is_null = is_null,
        };
    }
    
    /// Evaluate against null stats
    pub fn evaluateZoneMap(self: *const Self, has_nulls: bool, all_nulls: bool) PredicateResult {
        if (self.is_null) {
            // IS NULL
            if (!has_nulls) return .FALSE;
            if (all_nulls) return .TRUE;
            return .MAYBE;
        } else {
            // IS NOT NULL
            if (all_nulls) return .FALSE;
            if (!has_nulls) return .TRUE;
            return .MAYBE;
        }
    }
    
    /// Evaluate single value
    pub fn evaluate(self: *const Self, is_null: bool) bool {
        if (self.is_null) {
            return is_null;
        } else {
            return !is_null;
        }
    }
};

/// Constant predicate - always returns same result
pub const ConstantPredicate = struct {
    base: Predicate,
    result: bool,
    
    const Self = @This();
    
    pub fn init(result: bool) Self {
        return .{
            .base = Predicate.init(.CONSTANT),
            .result = result,
        };
    }
    
    pub fn alwaysTrue() Self {
        return Self.init(true);
    }
    
    pub fn alwaysFalse() Self {
        return Self.init(false);
    }
    
    pub fn evaluate(self: *const Self) bool {
        return self.result;
    }
    
    pub fn evaluateZoneMap(self: *const Self) PredicateResult {
        return if (self.result) .TRUE else .FALSE;
    }
};

/// Predicate value container
pub const PredicateValue = struct {
    value_type: ValueType,
    int_value: i64,
    float_value: f64,
    bool_value: bool,
    string_value: ?[]const u8,
    
    pub const ValueType = enum {
        NONE,
        INT,
        FLOAT,
        BOOL,
        STRING,
    };
    
    pub fn init() PredicateValue {
        return .{
            .value_type = .NONE,
            .int_value = 0,
            .float_value = 0,
            .bool_value = false,
            .string_value = null,
        };
    }
    
    pub fn fromInt(value: i64) PredicateValue {
        var v = PredicateValue.init();
        v.value_type = .INT;
        v.int_value = value;
        return v;
    }
    
    pub fn fromFloat(value: f64) PredicateValue {
        var v = PredicateValue.init();
        v.value_type = .FLOAT;
        v.float_value = value;
        return v;
    }
};

/// Compound AND predicate
pub const AndPredicate = struct {
    base: Predicate,
    left: *const Predicate,
    right: *const Predicate,
    
    pub fn init(left: *const Predicate, right: *const Predicate) AndPredicate {
        return .{
            .base = Predicate.init(.AND),
            .left = left,
            .right = right,
        };
    }
};

/// Compound OR predicate
pub const OrPredicate = struct {
    base: Predicate,
    left: *const Predicate,
    right: *const Predicate,
    
    pub fn init(left: *const Predicate, right: *const Predicate) OrPredicate {
        return .{
            .base = Predicate.init(.OR),
            .left = left,
            .right = right,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "column predicate zone map" {
    var pred = ColumnPredicate.init(0, .EQUAL, .INT64);
    pred.setIntValue(50);
    
    // Value in range
    try std.testing.expectEqual(PredicateResult.MAYBE, pred.evaluateZoneMap(0, 100));
    
    // Value out of range (too high)
    try std.testing.expectEqual(PredicateResult.FALSE, pred.evaluateZoneMap(0, 40));
    
    // Value out of range (too low)
    try std.testing.expectEqual(PredicateResult.FALSE, pred.evaluateZoneMap(60, 100));
    
    // Exact match
    try std.testing.expectEqual(PredicateResult.TRUE, pred.evaluateZoneMap(50, 50));
}

test "column predicate evaluate" {
    var pred = ColumnPredicate.init(0, .GREATER_THAN, .INT64);
    pred.setIntValue(10);
    
    try std.testing.expect(pred.evaluate(15));
    try std.testing.expect(!pred.evaluate(10));
    try std.testing.expect(!pred.evaluate(5));
}

test "null predicate" {
    var is_null_pred = NullPredicate.init(0, true);
    var not_null_pred = NullPredicate.init(0, false);
    
    // IS NULL
    try std.testing.expect(is_null_pred.evaluate(true));
    try std.testing.expect(!is_null_pred.evaluate(false));
    
    // IS NOT NULL
    try std.testing.expect(!not_null_pred.evaluate(true));
    try std.testing.expect(not_null_pred.evaluate(false));
}

test "constant predicate" {
    const always_true = ConstantPredicate.alwaysTrue();
    const always_false = ConstantPredicate.alwaysFalse();
    
    try std.testing.expect(always_true.evaluate());
    try std.testing.expect(!always_false.evaluate());
    
    try std.testing.expectEqual(PredicateResult.TRUE, always_true.evaluateZoneMap());
    try std.testing.expectEqual(PredicateResult.FALSE, always_false.evaluateZoneMap());
}

test "predicate value" {
    const int_val = PredicateValue.fromInt(42);
    try std.testing.expectEqual(@as(i64, 42), int_val.int_value);
    try std.testing.expectEqual(PredicateValue.ValueType.INT, int_val.value_type);
    
    const float_val = PredicateValue.fromFloat(3.14);
    try std.testing.expectEqual(@as(f64, 3.14), float_val.float_value);
}