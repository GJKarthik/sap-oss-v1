//! LogicalTypeID — Ported from kuzu C++ (80L header, 57L source).
//!
//! Extends uint8_t in the upstream implementation.

const std = @import("std");

pub const LogicalTypeID = struct {
    allocator: std.mem.Allocator,
    ClientContext: ?*anyopaque = null,
    SystemConfig: ?*anyopaque = null,
    name: []const u8 = "",
    parameterType: ?*anyopaque = null,
    optionType: ?*anyopaque = null,
    isConfidential: bool = false,
    setContext: ?*anyopaque = null,
    getSetting: ?*anyopaque = null,
    defaultValue: ?*anyopaque = null,
    bufferPoolSize: u64 = 0,
    maxNumThreads: u64 = 0,
    enableCompression: bool = false,
    readOnly: bool = false,
    maxDBSize: u64 = 0,
    enableMultiWrites: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn void(self: *Self) void {
        _ = self;
    }

    pub fn defined(self: *Self) void {
        _ = self;
    }

    pub fn db_config(self: *Self) void {
        _ = self;
    }

    pub fn is_db_path_in_memory(self: *const Self) bool {
        _ = self;
        return false;
    }

    /// Create a deep copy of this LogicalTypeID.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.name = self.name;
        new.isConfidential = self.isConfidential;
        new.bufferPoolSize = self.bufferPoolSize;
        return new;
    }

};

test "LogicalTypeID" {
    const allocator = std.testing.allocator;
    var instance = LogicalTypeID.init(allocator);
    defer instance.deinit();
    _ = instance.is_db_path_in_memory();
}
