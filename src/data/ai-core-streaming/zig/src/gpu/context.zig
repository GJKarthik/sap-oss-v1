//! GPU Context - Placeholder for bdc-aiprompt-streaming
//! This service focuses on Pulsar streaming and does not require full GPU support

const std = @import("std");

pub const GpuContext = struct {
    allocator: std.mem.Allocator,
    enabled: bool,

    pub fn init(allocator: std.mem.Allocator) GpuContext {
        return .{
            .allocator = allocator,
            .enabled = false,
        };
    }

    pub fn deinit(self: *GpuContext) void {
        _ = self;
    }
};