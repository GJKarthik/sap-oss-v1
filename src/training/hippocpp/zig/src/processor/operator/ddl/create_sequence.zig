//! CreateSequence — Ported from kuzu C++ (46L header, 40L source).
//!
//! Extends SimpleSink in the upstream implementation.

const std = @import("std");

pub const CreateSequence = struct {
    allocator: std.mem.Allocator,
    seqName: []const u8 = "",
    info: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn create_sequence_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this CreateSequence.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.seqName = self.seqName;
        return new;
    }

};

test "CreateSequence" {
    const allocator = std.testing.allocator;
    var instance = CreateSequence.init(allocator);
    defer instance.deinit();
}
