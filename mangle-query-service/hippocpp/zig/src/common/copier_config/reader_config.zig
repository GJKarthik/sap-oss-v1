//! ReaderConfig
const std = @import("std");

pub const ReaderConfig = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ReaderConfig {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ReaderConfig) void {
        _ = self;
    }
};

test "ReaderConfig" {
    const allocator = std.testing.allocator;
    var instance = ReaderConfig.init(allocator);
    defer instance.deinit();
}
