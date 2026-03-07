//! TableStatistics
const std = @import("std");

pub const TableStatistics = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TableStatistics {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *TableStatistics) void {
        _ = self;
    }
};

test "TableStatistics" {
    const allocator = std.testing.allocator;
    var instance = TableStatistics.init(allocator);
    defer instance.deinit();
}
