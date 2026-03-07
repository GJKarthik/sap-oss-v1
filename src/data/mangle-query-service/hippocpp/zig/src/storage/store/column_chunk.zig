//! ColumnChunk
const std = @import("std");

pub const ColumnChunk = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ColumnChunk {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ColumnChunk) void {
        _ = self;
    }
};

test "ColumnChunk" {
    const allocator = std.testing.allocator;
    var instance = ColumnChunk.init(allocator);
    defer instance.deinit();
}
