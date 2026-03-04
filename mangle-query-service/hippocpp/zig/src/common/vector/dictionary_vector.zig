//! DictionaryVector
const std = @import("std");

pub const DictionaryVector = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) DictionaryVector { return .{ .allocator = allocator }; }
    pub fn deinit(self: *DictionaryVector) void { _ = self; }
};

test "DictionaryVector" {
    const allocator = std.testing.allocator;
    var instance = DictionaryVector.init(allocator);
    defer instance.deinit();
}
