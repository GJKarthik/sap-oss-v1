pub const TaskManagerStatus = enum {
    pending,
    running,
    completed,
    failed,
};

pub const TestType = enum {
    benchmark,
    scan,

    pub fn parse(raw: []const u8) ?TestType {
        if (std.mem.eql(u8, raw, "benchmark")) return .benchmark;
        if (std.mem.eql(u8, raw, "scan")) return .scan;
        return null;
    }
};

const std = @import("std");

test "parse test type" {
    try std.testing.expect(TestType.parse("benchmark") == .benchmark);
    try std.testing.expect(TestType.parse("scan") == .scan);
    try std.testing.expect(TestType.parse("invalid") == null);
}
