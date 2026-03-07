//! VarLenColExtend
const std = @import("std");

pub const VarLenColExtend = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) VarLenColExtend { return .{ .allocator = allocator }; }
    pub fn deinit(self: *VarLenColExtend) void { _ = self; }
};

test "VarLenColExtend" {
    const allocator = std.testing.allocator;
    var instance = VarLenColExtend.init(allocator);
    defer instance.deinit();
}
