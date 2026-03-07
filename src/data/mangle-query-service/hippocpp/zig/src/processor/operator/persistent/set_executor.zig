//! Executor for applying SET mutations.

const std = @import("std");
const set_mod = @import("set.zig");

pub const SetExecutor = struct {
    allocator: std.mem.Allocator,
    applied_mutations: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) SetExecutor {
        return .{ .allocator = allocator };
    }

    pub fn execute(self: *SetExecutor, batch: *const set_mod.SetBatch) void {
        self.applied_mutations += @intCast(batch.mutations.items.len);
    }
};
