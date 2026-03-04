//! ResultCollector
const std = @import("std");

pub const ResultCollector = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ResultCollector {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ResultCollector) void {
        _ = self;
    }
};

test "ResultCollector" {
    const allocator = std.testing.allocator;
    var instance = ResultCollector.init(allocator);
    defer instance.deinit();
}
