//! BlobColumn
const std = @import("std");

pub const BlobColumn = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BlobColumn { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BlobColumn) void { _ = self; }
};

test "BlobColumn" {
    const allocator = std.testing.allocator;
    var instance = BlobColumn.init(allocator);
    defer instance.deinit();
}
