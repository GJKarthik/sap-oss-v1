//! ForeignTableEntry
const std = @import("std");

pub const ForeignTableEntry = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ForeignTableEntry { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ForeignTableEntry) void { _ = self; }
};

test "ForeignTableEntry" {
    const allocator = std.testing.allocator;
    var instance = ForeignTableEntry.init(allocator);
    defer instance.deinit();
}
