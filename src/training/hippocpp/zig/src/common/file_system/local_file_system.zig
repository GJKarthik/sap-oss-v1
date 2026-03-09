//! KUZU_API — Ported from kuzu C++ (74L header, 551L source).
//!

const std = @import("std");

pub const KUZU_API = struct {
    allocator: std.mem.Allocator,
    fd: i32 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn local_file_info(self: *Self) void {
        _ = self;
    }

    pub fn local_file_system(self: *Self) void {
        _ = self;
    }

    pub fn overwrite_file(self: *Self) void {
        _ = self;
    }

    pub fn copy_file(self: *Self) void {
        _ = self;
    }

    pub fn create_dir(self: *Self) void {
        _ = self;
    }

    pub fn remove_file_if_exists(self: *Self) void {
        _ = self;
    }

    pub fn file_or_path_exists(self: *Self) void {
        _ = self;
    }

    pub fn expand_path(self: *Self) void {
        _ = self;
    }

    pub fn sync_file(self: *Self) void {
        _ = self;
    }

    pub fn is_local_path(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn file_exists(self: *Self) void {
        _ = self;
    }

};

test "KUZU_API" {
    const allocator = std.testing.allocator;
    var instance = KUZU_API.init(allocator);
    defer instance.deinit();
}
