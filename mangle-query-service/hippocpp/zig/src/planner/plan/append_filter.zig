//! AppendFilter
const std = @import("std");

pub const AppendFilter = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AppendFilter {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AppendFilter) void {
        _ = self;
    }
};

test "AppendFilter" {
    const allocator = std.testing.allocator;
    var instance = AppendFilter.init(allocator);
    defer instance.deinit();
}
