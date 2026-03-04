//! CurrentSettingFunction
const std = @import("std");

pub const CurrentSettingFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) CurrentSettingFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *CurrentSettingFunction) void { _ = self; }
};

test "CurrentSettingFunction" {
    const allocator = std.testing.allocator;
    var instance = CurrentSettingFunction.init(allocator);
    defer instance.deinit();
}
