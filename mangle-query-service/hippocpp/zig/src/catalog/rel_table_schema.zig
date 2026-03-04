//! RelTableSchema
const std = @import("std");

pub const RelTableSchema = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RelTableSchema { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RelTableSchema) void { _ = self; }
};

test "RelTableSchema" {
    const allocator = std.testing.allocator;
    var instance = RelTableSchema.init(allocator);
    defer instance.deinit();
}
