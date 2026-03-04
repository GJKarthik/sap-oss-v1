//! ArrowSchema
const std = @import("std");

pub const ArrowSchema = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ArrowSchema { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ArrowSchema) void { _ = self; }
};

test "ArrowSchema" {
    const allocator = std.testing.allocator;
    var instance = ArrowSchema.init(allocator);
    defer instance.deinit();
}
