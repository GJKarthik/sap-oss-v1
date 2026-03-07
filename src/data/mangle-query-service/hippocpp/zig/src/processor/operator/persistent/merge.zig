//! MERGE operation runtime support.

const std = @import("std");

pub const MergeResult = struct {
    matched: u64 = 0,
    created: u64 = 0,
};

pub const MergeExecutor = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MergeExecutor {
        return .{ .allocator = allocator };
    }

    pub fn apply(self: *MergeExecutor, found_existing: bool, result: *MergeResult) void {
        _ = self;
        if (found_existing) {
            result.matched += 1;
        } else {
            result.created += 1;
        }
    }
};
