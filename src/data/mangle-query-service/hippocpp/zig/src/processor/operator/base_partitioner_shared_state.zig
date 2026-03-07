//! Shared state for partitioned operators.

const std = @import("std");

pub const BasePartitionerSharedState = struct {
    total_partitions: usize,
    next_partition: usize = 0,
    completed_partitions: usize = 0,

    pub fn init(total_partitions: usize) BasePartitionerSharedState {
        return .{ .total_partitions = total_partitions };
    }

    pub fn acquireNext(self: *BasePartitionerSharedState) ?usize {
        if (self.next_partition >= self.total_partitions) return null;
        const idx = self.next_partition;
        self.next_partition += 1;
        return idx;
    }

    pub fn markCompleted(self: *BasePartitionerSharedState) void {
        if (self.completed_partitions < self.total_partitions) {
            self.completed_partitions += 1;
        }
    }
};

test "partitioner shared state" {
    var state = BasePartitionerSharedState.init(2);
    try std.testing.expectEqual(@as(usize, 0), state.acquireNext().?);
    try std.testing.expectEqual(@as(usize, 1), state.acquireNext().?);
    try std.testing.expect(state.acquireNext() == null);
}
