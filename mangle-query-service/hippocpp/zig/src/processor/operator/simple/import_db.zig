//! IMPORT DATABASE operator support.

const std = @import("std");

pub const ImportPlan = struct {
    source_dir: []const u8,
    allow_overwrite: bool = false,
};

pub fn validateImportPlan(plan: ImportPlan) !void {
    if (plan.source_dir.len == 0) return error.InvalidImportSource;
    if (std.mem.eql(u8, plan.source_dir, ":memory:")) return error.InvalidImportSource;
}

test "validate import plan" {
    try validateImportPlan(.{ .source_dir = "/tmp/export" });
}
