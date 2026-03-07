//! InternalID
const std = @import("std");

pub const InternalID = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) InternalID { return .{ .allocator = allocator }; }
    pub fn deinit(self: *InternalID) void { _ = self; }
};

test "InternalID" {
    const allocator = std.testing.allocator;
    var instance = InternalID.init(allocator);
    defer instance.deinit();
}
