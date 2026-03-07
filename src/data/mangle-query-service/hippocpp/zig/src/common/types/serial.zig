//! Serial
const std = @import("std");

pub const Serial = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Serial { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Serial) void { _ = self; }
};

test "Serial" {
    const allocator = std.testing.allocator;
    var instance = Serial.init(allocator);
    defer instance.deinit();
}
