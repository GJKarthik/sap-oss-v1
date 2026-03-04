//! IndexScan
const std = @import("std");

pub const IndexScan = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) IndexScan {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *IndexScan) void {
        _ = self;
    }
};

test "IndexScan" {
    const allocator = std.testing.allocator;
    var instance = IndexScan.init(allocator);
    defer instance.deinit();
}
