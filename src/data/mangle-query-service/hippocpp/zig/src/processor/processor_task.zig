//! Processor task scheduling unit.

const std = @import("std");

pub const TaskStatus = enum {
    pending,
    running,
    completed,
    failed,
};

pub const ProcessorTask = struct {
    id: u64,
    pipeline_id: u64,
    status: TaskStatus = .pending,
    retries: u8 = 0,

    pub fn init(id: u64, pipeline_id: u64) ProcessorTask {
        return .{
            .id = id,
            .pipeline_id = pipeline_id,
        };
    }

    pub fn markRunning(self: *ProcessorTask) void {
        self.status = .running;
    }

    pub fn markCompleted(self: *ProcessorTask) void {
        self.status = .completed;
    }

    pub fn markFailed(self: *ProcessorTask) void {
        self.status = .failed;
        self.retries += 1;
    }
};

test "processor task status transitions" {
    var task = ProcessorTask.init(1, 100);
    try std.testing.expectEqual(TaskStatus.pending, task.status);

    task.markRunning();
    try std.testing.expectEqual(TaskStatus.running, task.status);

    task.markFailed();
    try std.testing.expectEqual(TaskStatus.failed, task.status);
    try std.testing.expectEqual(@as(u8, 1), task.retries);
}
