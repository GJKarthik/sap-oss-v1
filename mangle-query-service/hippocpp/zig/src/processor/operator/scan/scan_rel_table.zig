//! ScanRelTable
const std = @import("std");

pub const ScanRelTable = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ScanRelTable {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ScanRelTable) void {
        _ = self;
    }
};

test "ScanRelTable" {
    const allocator = std.testing.allocator;
    var instance = ScanRelTable.init(allocator);
    defer instance.deinit();
}
