//! Sink
const std = @import("std");

pub const Sink = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Sink { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Sink) void { _ = self; }
};

test "Sink" {
    const allocator = std.testing.allocator;
    var instance = Sink.init(allocator);
    defer instance.deinit();
}
