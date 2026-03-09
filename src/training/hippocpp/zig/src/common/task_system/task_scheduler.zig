//! KUZU_API — Ported from kuzu C++ (112L header, 230L source).
//!

const std = @import("std");

pub const KUZU_API = struct {
    allocator: std.mem.Allocator,
    task: ?*?*anyopaque = null,
    ID: u64 = 0,
    stopWorkerThreads: bool = false,
    workerThreads: std.ArrayList(?*anyopaque) = .{},
    taskSchedulerMtx: ?*anyopaque = null,
    cv: ?*anyopaque = null,
    nextScheduledTaskID: u64 = 0,
    threadQos: u32 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn task(self: *Self) void {
        _ = self;
    }

    pub fn exception(self: *Self) void {
        _ = self;
    }

    pub fn defined(self: *Self) void {
        _ = self;
    }

    pub fn task_scheduler(self: *Self) void {
        _ = self;
    }

    pub fn another(self: *Self) void {
        _ = self;
    }

    pub fn schedule_task_and_wait_or_error(self: *Self) void {
        _ = self;
    }

    pub fn run_worker_thread(self: *Self) void {
        _ = self;
    }

    pub fn remove_erroring_task(self: *Self) void {
        _ = self;
    }

    pub fn run_task(self: *Self) void {
        _ = self;
    }

};

test "KUZU_API" {
    const allocator = std.testing.allocator;
    var instance = KUZU_API.init(allocator);
    defer instance.deinit();
}
