//! RelMultiplicity
const std = @import("std");

pub const RelMultiplicity = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RelMultiplicity { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RelMultiplicity) void { _ = self; }
};

test "RelMultiplicity" {
    const allocator = std.testing.allocator;
    var instance = RelMultiplicity.init(allocator);
    defer instance.deinit();
}
