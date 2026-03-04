//! CreateClauseParsed
const std = @import("std");

pub const CreateClauseParsed = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) CreateClauseParsed { return .{ .allocator = allocator }; }
    pub fn deinit(self: *CreateClauseParsed) void { _ = self; }
};

test "CreateClauseParsed" {
    const allocator = std.testing.allocator;
    var instance = CreateClauseParsed.init(allocator);
    defer instance.deinit();
}
