//! planner/plan/append_simple parity module.

const std = @import("std");

pub const PlannerStage = struct {
    id: []const u8,

    pub fn init(id: []const u8) PlannerStage {
        return .{ .id = id };
    }

    pub fn effectiveId(self: *const PlannerStage) []const u8 {
        return if (self.id.len == 0) plannerPath() else self.id;
    }

    pub fn idMatches(self: *const PlannerStage, expected: []const u8) bool {
        return std.mem.eql(u8, self.effectiveId(), expected);
    }
};

pub fn plannerPath() []const u8 {
    return "planner/plan/append_simple";
}

test "append_simple planner path" {
    try std.testing.expectEqualStrings("planner/plan/append_simple", plannerPath());
}

test "append_simple planner id fallback" {
    var stage = PlannerStage.init("");
    try std.testing.expect(stage.idMatches("planner/plan/append_simple"));
}
