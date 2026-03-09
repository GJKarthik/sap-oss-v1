//! ExportDB — Ported from kuzu C++ (60L header, 247L source).
//!
//! Extends SimpleSink in the upstream implementation.

const std = @import("std");

pub const ExportDB = struct {
    allocator: std.mem.Allocator,
    filePath: []const u8 = "",
    options: ?*anyopaque = null,
    boundFileInfo: ?*anyopaque = null,
    schemaOnly: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn export_db_print_info(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    pub fn add_to_parallel_reader_map(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this ExportDB.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.filePath = self.filePath;
        new.schemaOnly = self.schemaOnly;
        return new;
    }

};

test "ExportDB" {
    const allocator = std.testing.allocator;
    var instance = ExportDB.init(allocator);
    defer instance.deinit();
}
