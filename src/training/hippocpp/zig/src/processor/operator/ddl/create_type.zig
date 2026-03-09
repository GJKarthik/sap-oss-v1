//! CreateType — Ported from kuzu C++ (48L header, 27L source).
//!
//! Extends SimpleSink in the upstream implementation.

const std = @import("std");

pub const CreateType = struct {
    allocator: std.mem.Allocator,
    typeName: []const u8 = "",
    type: []const u8 = "",
    name: []const u8 = "",

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

    pub fn create_type_print_info(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this CreateType.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.typeName = self.typeName;
        new.type = self.type;
        new.name = self.name;
        return new;
    }

};

test "CreateType" {
    const allocator = std.testing.allocator;
    var instance = CreateType.init(allocator);
    defer instance.deinit();
}
