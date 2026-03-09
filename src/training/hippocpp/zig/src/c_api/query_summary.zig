//! C API query summary representation.

const std = @import("std");

pub const QuerySummaryC = struct {
    compiling_time_ms: f64 = 0,
    execution_time_ms: f64 = 0,
};

pub fn getCompilingTime(summary: *const QuerySummaryC) f64 {
    return summary.compiling_time_ms;
}

pub fn getExecutionTime(summary: *const QuerySummaryC) f64 {
    return summary.execution_time_ms;
}

test "query summary getters" {
    const summary = QuerySummaryC{
        .compiling_time_ms = 1.25,
        .execution_time_ms = 3.75,
    };
    try std.testing.expectEqual(@as(f64, 1.25), getCompilingTime(&summary));
    try std.testing.expectEqual(@as(f64, 3.75), getExecutionTime(&summary));
}
