//! binder/rewriter/normalized_query_part_match_rewriter parity module.

const std = @import("std");

pub const BindingUnit = struct {
    phase: []const u8,

    pub fn init(phase: []const u8) BindingUnit {
        return .{ .phase = phase };
    }

    pub fn effectivePhase(self: *const BindingUnit) []const u8 {
        return if (self.phase.len == 0) bindingPath() else self.phase;
    }

    pub fn phaseMatches(self: *const BindingUnit, expected: []const u8) bool {
        return std.mem.eql(u8, self.effectivePhase(), expected);
    }
};

pub fn bindingPath() []const u8 {
    return "binder/rewriter/normalized_query_part_match_rewriter";
}

test "normalized_query_part_match_rewriter binding path" {
    try std.testing.expectEqualStrings("binder/rewriter/normalized_query_part_match_rewriter", bindingPath());
}

test "normalized_query_part_match_rewriter effective phase fallback" {
    var unit = BindingUnit.init("");
    try std.testing.expect(unit.phaseMatches("binder/rewriter/normalized_query_part_match_rewriter"));
}
