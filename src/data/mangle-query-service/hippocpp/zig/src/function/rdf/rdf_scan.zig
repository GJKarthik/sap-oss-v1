//! RDFScanFunction
const std = @import("std");

pub const RDFScanFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RDFScanFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RDFScanFunction) void { _ = self; }
};

test "RDFScanFunction" {
    const allocator = std.testing.allocator;
    var instance = RDFScanFunction.init(allocator);
    defer instance.deinit();
}
