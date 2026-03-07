//! Async Pipeline - Placeholder for bdc-aiprompt-streaming
//! This service focuses on Pulsar streaming and does not require full GPU support

const std = @import("std");

pub const AsyncPipeline = struct {
    allocator: std.mem.Allocator,
    enabled: bool,

    pub fn init(allocator: std.mem.Allocator) AsyncPipeline {
        return .{
            .allocator = allocator,
            .enabled = false,
        };
    }

    pub fn deinit(self: *AsyncPipeline) void {
        _ = self;
    }
};