//! SerialColumn
const std = @import("std");

pub const SerialColumn = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) SerialColumn {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *SerialColumn) void {
        _ = self;
    }
};

test "SerialColumn" {
    const allocator = std.testing.allocator;
    var instance = SerialColumn.init(allocator);
    defer instance.deinit();
}
