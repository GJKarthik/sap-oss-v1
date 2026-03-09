//! ClientContext — Ported from kuzu C++ (61L header, 79L source).
//!

const std = @import("std");

pub const ClientContext = struct {
    allocator: std.mem.Allocator,
    ClientContext: ?*anyopaque = null,
    display: ?*anyopaque = null,
    trackProgress: ?*anyopaque = null,
    numPipelines: u32 = 0,
    numPipelinesFinished: u32 = 0,
    progressBarLock: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn progress_bar(self: *Self) void {
        _ = self;
    }

    pub fn add_pipeline(self: *Self) void {
        _ = self;
    }

    pub fn finish_pipeline(self: *Self) void {
        _ = self;
    }

    pub fn end_progress(self: *Self) void {
        _ = self;
    }

    pub fn start_progress(self: *Self) void {
        _ = self;
    }

    pub fn toggle_progress_bar_printing(self: *Self) void {
        _ = self;
    }

    pub fn update_progress(self: *Self) void {
        _ = self;
    }

    pub fn set_display(self: *Self) void {
        _ = self;
    }

    pub fn get_progress_bar_printing(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn reset_progress_bar(self: *Self) void {
        _ = self;
    }

    pub fn update_display(self: *Self) void {
        _ = self;
    }

};

test "ClientContext" {
    const allocator = std.testing.allocator;
    var instance = ClientContext.init(allocator);
    defer instance.deinit();
}
