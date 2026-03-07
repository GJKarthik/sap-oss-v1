//! StringColumn
const std = @import("std");

pub const StringColumn = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) StringColumn {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *StringColumn) void {
        _ = self;
    }
};

test "StringColumn" {
    const allocator = std.testing.allocator;
    var instance = StringColumn.init(allocator);
    defer instance.deinit();
}
