//! PostgresScanner
const std = @import("std");

pub const PostgresScanner = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) PostgresScanner {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *PostgresScanner) void {
        _ = self;
    }
};

test "PostgresScanner" {
    const allocator = std.testing.allocator;
    var instance = PostgresScanner.init(allocator);
    defer instance.deinit();
}
