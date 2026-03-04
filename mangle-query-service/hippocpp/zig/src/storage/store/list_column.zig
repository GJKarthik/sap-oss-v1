//! ListColumn
const std = @import("std");

pub const ListColumn = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ListColumn {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ListColumn) void {
        _ = self;
    }
};

test "ListColumn" {
    const allocator = std.testing.allocator;
    var instance = ListColumn.init(allocator);
    defer instance.deinit();
}
