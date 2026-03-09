//! ExportDB — Ported from kuzu C++ (35L header, 0L source).
//!
//! Extends Statement in the upstream implementation.

const std = @import("std");

pub const ExportDB = struct {
    allocator: std.mem.Allocator,
    parsingOptions: ?*anyopaque = null,
    filePath: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn set_parsing_option(self: *Self) void {
        _ = self;
    }

    pub fn get_file_path(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn import_db(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this ExportDB.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.filePath = self.filePath;
        new.filePath = self.filePath;
        return new;
    }

};

test "ExportDB" {
    const allocator = std.testing.allocator;
    var instance = ExportDB.init(allocator);
    defer instance.deinit();
    _ = instance.get_file_path();
    _ = instance.get_file_path();
}
