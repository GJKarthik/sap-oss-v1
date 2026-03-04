//! EmptyResult
const std = @import("std");

pub const EmptyResult = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) EmptyResult {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *EmptyResult) void {
        _ = self;
    }
};

test "EmptyResult" {
    const allocator = std.testing.allocator;
    var instance = EmptyResult.init(allocator);
    defer instance.deinit();
}
