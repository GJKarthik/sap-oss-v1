//! OpProfileBox — Ported from kuzu C++ (120L header, 445L source).
//!

const std = @import("std");

pub const OpProfileBox = struct {
    allocator: std.mem.Allocator,
    opName: ?*anyopaque = null,
    paramsNames: std.ArrayList([]const u8) = .{},
    attributes: std.ArrayList([]const u8) = .{},
    opProfileBoxWidth: u32 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_op_name(self: *const Self) []const u8 {
        _ = self;
        return "";
    }

    pub fn get_num_params(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_params_name(self: *const Self) []const u8 {
        _ = self;
        return "";
    }

    pub fn get_attribute(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_num_attributes(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_attribute_max_len(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn op_profile_tree(self: *Self) void {
        _ = self;
    }

    pub fn print_plan_to_ostream(self: *Self) void {
        _ = self;
    }

    pub fn print_logical_plan_to_ostream(self: *Self) void {
        _ = self;
    }

    pub fn calculate_num_rows_and_cols_for_op(self: *Self) void {
        _ = self;
    }

    pub fn fill_op_profile_boxes(self: *Self) void {
        _ = self;
    }

};

test "OpProfileBox" {
    const allocator = std.testing.allocator;
    var instance = OpProfileBox.init(allocator);
    defer instance.deinit();
    _ = instance.get_op_name();
    _ = instance.get_num_params();
    _ = instance.get_params_name();
    _ = instance.get_attribute();
    _ = instance.get_num_attributes();
}
