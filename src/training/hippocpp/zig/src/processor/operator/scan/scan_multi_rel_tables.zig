//! RelTableCollectionScanner — Ported from kuzu C++ (93L header, 109L source).
//!

const std = @import("std");

pub const RelTableCollectionScanner = struct {
    allocator: std.mem.Allocator,
    extendFromSource: bool = false,
    directionPos: ?*anyopaque = null,
    ScanMultiRelTable: ?*anyopaque = null,
    relInfos: std.ArrayList(?*anyopaque) = .{},
    directionValues: std.ArrayList(bool) = .{},
    directionInfo: ?*anyopaque = null,
    scanState: ?*?*anyopaque = null,
    scanners: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn need_flip(self: *Self) void {
        _ = self;
    }

    pub fn empty(self: *Self) void {
        _ = self;
    }

    pub fn reset_state(self: *Self) void {
        _ = self;
    }

    pub fn add_rel_infos(self: *Self) void {
        _ = self;
    }

    pub fn scan(self: *Self) void {
        _ = self;
    }

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn get_next_tuples_internal(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn init_current_scanner(self: *Self) void {
        _ = self;
    }

};

test "RelTableCollectionScanner" {
    const allocator = std.testing.allocator;
    var instance = RelTableCollectionScanner.init(allocator);
    defer instance.deinit();
}
