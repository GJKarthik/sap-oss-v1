//! CsvScan — graph database engine module.
//!

const std = @import("std");

pub const CsvScan = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }



};

test "CsvScan" {
    const allocator = std.testing.allocator;
    var instance = CsvScan.init(allocator);
    defer instance.deinit();
}
