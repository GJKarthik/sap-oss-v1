//! ScanNodeTable
const std = @import("std");

pub const ScanNodeTable = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ScanNodeTable {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ScanNodeTable) void {
        _ = self;
    }
};

test "ScanNodeTable" {
    const allocator = std.testing.allocator;
    var instance = ScanNodeTable.init(allocator);
    defer instance.deinit();
}
