//! CurrentDate — graph database engine module.
//!

const std = @import("std");

pub const CurrentDate = struct {
    allocator: std.mem.Allocator,
    name: []const u8 = "",

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Perform execute operation.
    pub fn execute(self: *Self) !void {
        _ = self;
    }

    pub fn bind_func(self: *Self) !void {
        _ = self;
    }

    pub fn get_function_set(self: *const Self) []const u8 {
        _ = self;
        return "current_date";
    }

};

test "CurrentDate" {
    const allocator = std.testing.allocator;
    var instance = CurrentDate.init(allocator);
    defer instance.deinit();
    _ = instance.get_function_set();
}
