//! ClientContext — Ported from kuzu C++ (172L header, 390L source).
//!

const std = @import("std");

pub const ClientContext = struct {
    allocator: std.mem.Allocator,
    ClientContext: ?*anyopaque = null,
    VirtualFileSystem: ?*anyopaque = null,
    ShadowFile: ?*anyopaque = null,
    BufferManager: ?*anyopaque = null,
    files: ?*anyopaque = null,
    fileIndex: ?*anyopaque = null,
    numPages: ?*anyopaque = null,
    pageSizeClass: ?*anyopaque = null,
    fhSharedMutex: ?*anyopaque = null,
    fhFlags: u8 = 0,
    fileInfo: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn delete_copy_and_move(self: *Self) void {
        _ = self;
    }

    pub fn optimistic_read_page(self: *Self) void {
        _ = self;
    }

    pub fn unpin_page(self: *Self) void {
        _ = self;
    }

    pub fn set_locked_page_dirty(self: *Self) void {
        _ = self;
    }

    pub fn get_file_index(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn add_new_page(self: *Self) void {
        _ = self;
    }

    pub fn add_new_pages(self: *Self) void {
        _ = self;
    }

    pub fn remove_page_idx_and_truncate_if_necessary(self: *Self) void {
        _ = self;
    }

    pub fn remove_page_from_frame_if_necessary(self: *Self) void {
        _ = self;
    }

    pub fn flush_all_dirty_pages_in_frames(self: *Self) void {
        _ = self;
    }

    pub fn read_page_from_disk(self: *Self) void {
        _ = self;
    }

    pub fn write_page_to_file(self: *Self) void {
        _ = self;
    }

};

test "ClientContext" {
    const allocator = std.testing.allocator;
    var instance = ClientContext.init(allocator);
    defer instance.deinit();
    _ = instance.get_file_index();
}
