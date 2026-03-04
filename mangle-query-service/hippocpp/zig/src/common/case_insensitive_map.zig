//! CaseInsensitiveMap
const std = @import("std");

pub const CaseInsensitiveMap = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) CaseInsensitiveMap { return .{ .allocator = allocator }; }
    pub fn deinit(self: *CaseInsensitiveMap) void { _ = self; }
};

test "CaseInsensitiveMap" {
    const allocator = std.testing.allocator;
    var instance = CaseInsensitiveMap.init(allocator);
    defer instance.deinit();
}
