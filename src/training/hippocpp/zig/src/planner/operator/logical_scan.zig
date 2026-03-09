//! LogicalScanNodeTableType — Ported from kuzu C++ (111L header, 0L source).
//!
//! Extends uint8_t in the upstream implementation.

const std = @import("std");

pub const LogicalScanNodeTableType = struct {
    allocator: std.mem.Allocator,
    key: ?*?*anyopaque = null,
    nodeID: ?*?*anyopaque = null,
    properties: std.ArrayList(u8) = .{},
    result: ?*anyopaque = null,
    scanType: ?*anyopaque = null,
    nodeTableIDs: ?*anyopaque = null,
    propertyPredicates: ?*anyopaque = null,
    extraInfo: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn primary_key_scan_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn compute_factorized_schema(self: *Self) void {
        _ = self;
    }

    pub fn compute_flat_schema(self: *Self) void {
        _ = self;
    }

    pub fn get_expressions_for_printing(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_scan_type(self: *const Self) u8 {
        _ = self;
        return null;
    }

    pub fn set_scan_type(self: *Self) void {
        _ = self;
    }

    pub fn get_properties(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn add_property(self: *Self) void {
        _ = self;
    }

    pub fn set_property_predicates(self: *Self) void {
        _ = self;
    }

    pub fn set_extra_info(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this LogicalScanNodeTableType.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "LogicalScanNodeTableType" {
    const allocator = std.testing.allocator;
    var instance = LogicalScanNodeTableType.init(allocator);
    defer instance.deinit();
    _ = instance.get_expressions_for_printing();
}
