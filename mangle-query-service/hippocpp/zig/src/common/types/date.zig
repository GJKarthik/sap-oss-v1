//! Date
const std = @import("std");

pub const Date = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Date {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Date) void {
        _ = self;
    }
};

test "Date" {
    const allocator = std.testing.allocator;
    var instance = Date.init(allocator);
    defer instance.deinit();
}
