//! VarList
const std = @import("std");

pub const VarList = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) VarList { return .{ .allocator = allocator }; }
    pub fn deinit(self: *VarList) void { _ = self; }
};

test "VarList" {
    const allocator = std.testing.allocator;
    var instance = VarList.init(allocator);
    defer instance.deinit();
}
