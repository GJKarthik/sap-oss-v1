//! planner/query_planner parity module.

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
    return "planner/query_planner";
}

test "query_planner planner path" {
    try std.testing.expectEqualStrings("planner/query_planner", plannerPath());
}

test "query_planner planner id fallback" {
    var stage = PlannerStage.init("");
    try std.testing.expect(stage.idMatches("planner/query_planner"));
}
