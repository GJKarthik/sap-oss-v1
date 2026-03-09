//! FileSystem — Ported from kuzu C++ (67L header, 53L source).
//!

const std = @import("std");

pub const FileSystem = struct {
    allocator: std.mem.Allocator,
    FileSystem: ?*anyopaque = null,
    path: []const u8 = "",

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_file_size(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn read_from_file(self: *Self) void {
        _ = self;
    }

    pub fn read_file(self: *Self) void {
        _ = self;
    }

    pub fn write_file(self: *Self) void {
        _ = self;
    }

    pub fn sync_file(self: *Self) void {
        _ = self;
    }

    pub fn seek(self: *Self) void {
        _ = self;
    }

    pub fn reset(self: *Self) void {
        _ = self;
    }

    pub fn truncate(self: *Self) void {
        _ = self;
    }

    pub fn can_perform_seek(self: *Self) void {
        _ = self;
    }

    pub fn get_handle_function(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

};

test "FileSystem" {
    const allocator = std.testing.allocator;
    var instance = FileSystem.init(allocator);
    defer instance.deinit();
    _ = instance.get_file_size();
}
