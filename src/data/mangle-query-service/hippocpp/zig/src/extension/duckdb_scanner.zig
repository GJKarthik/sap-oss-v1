//! DuckDBScanner
const std = @import("std");

pub const DuckDBScanner = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) DuckDBScanner {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *DuckDBScanner) void {
        _ = self;
    }
};

test "DuckDBScanner" {
    const allocator = std.testing.allocator;
    var instance = DuckDBScanner.init(allocator);
    defer instance.deinit();
}
