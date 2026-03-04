//! VarLenAdjExtend
const std = @import("std");

pub const VarLenAdjExtend = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) VarLenAdjExtend { return .{ .allocator = allocator }; }
    pub fn deinit(self: *VarLenAdjExtend) void { _ = self; }
};

test "VarLenAdjExtend" {
    const allocator = std.testing.allocator;
    var instance = VarLenAdjExtend.init(allocator);
    defer instance.deinit();
}
