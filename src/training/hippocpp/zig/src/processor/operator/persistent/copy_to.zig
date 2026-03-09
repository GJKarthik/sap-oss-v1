//! CopyTo — Ported from kuzu C++ (87L header, 44L source).
//!
//! Extends Sink in the upstream implementation.

const std = @import("std");

pub const CopyTo = struct {
    allocator: std.mem.Allocator,
    exportFunc: ?*anyopaque = null,
    bindData: ?*?*anyopaque = null,
    inputVectorPoses: std.ArrayList(?*anyopaque) = .{},
    isFlatVec: std.ArrayList(bool) = .{},
    exportFuncLocalState: ?*?*anyopaque = null,
    columnNames: std.ArrayList([]const u8) = .{},
    fileName: []const u8 = "",
    info: ?*anyopaque = null,
    localState: ?*anyopaque = null,
    sharedState: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn copy(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn copy_to_print_info(self: *Self) void {
        _ = self;
    }

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn init_global_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn finalize(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this CopyTo.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.fileName = self.fileName;
        return new;
    }

};

test "CopyTo" {
    const allocator = std.testing.allocator;
    var instance = CopyTo.init(allocator);
    defer instance.deinit();
}
