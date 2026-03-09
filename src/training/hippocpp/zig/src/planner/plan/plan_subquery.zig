//! PlanSubquery — graph database engine module.
//!
//! Implements LogicalOperator interface for PlanSubquery operations.

const std = @import("std");

pub const PlanSubquery = struct {
    allocator: std.mem.Allocator,
    cardinality: u64 = 0,
    cost: f64 = 0.0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn compute_schema(self: *Self) !void {
        _ = self;
    }

    pub fn get_expressions_for_printing(self: *const Self) []const u8 {
        _ = self;
        return "plan_subquery";
    }

    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.cardinality = self.cardinality;
        new.cost = self.cost;
        return new;
    }

};

test "PlanSubquery" {
    const allocator = std.testing.allocator;
    var instance = PlanSubquery.init(allocator);
    defer instance.deinit();
    _ = instance.get_expressions_for_printing();
}
