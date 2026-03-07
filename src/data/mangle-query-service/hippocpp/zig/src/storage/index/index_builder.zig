//! IndexBuilder
const std = @import("std");

pub const IndexBuilder = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) IndexBuilder {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *IndexBuilder) void {
        _ = self;
    }
};

test "IndexBuilder" {
    const allocator = std.testing.allocator;
    var instance = IndexBuilder.init(allocator);
    defer instance.deinit();
}
