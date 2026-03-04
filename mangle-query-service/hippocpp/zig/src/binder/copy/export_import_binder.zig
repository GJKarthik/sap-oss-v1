//! ExportImportBinder
const std = @import("std");

pub const ExportImportBinder = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ExportImportBinder { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ExportImportBinder) void { _ = self; }
};

test "ExportImportBinder" {
    const allocator = std.testing.allocator;
    var instance = ExportImportBinder.init(allocator);
    defer instance.deinit();
}
