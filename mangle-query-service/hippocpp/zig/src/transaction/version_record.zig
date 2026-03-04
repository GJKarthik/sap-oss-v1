//! VersionRecord
const std = @import("std");

pub const VersionRecord = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) VersionRecord { return .{ .allocator = allocator }; }
    pub fn deinit(self: *VersionRecord) void { _ = self; }
};

test "VersionRecord" {
    const allocator = std.testing.allocator;
    var instance = VersionRecord.init(allocator);
    defer instance.deinit();
}
