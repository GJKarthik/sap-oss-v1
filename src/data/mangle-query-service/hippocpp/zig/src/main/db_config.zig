//! DBConfig
const std = @import("std");

pub const DBConfig = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) DBConfig {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *DBConfig) void {
        _ = self;
    }
};

test "DBConfig" {
    const allocator = std.testing.allocator;
    var instance = DBConfig.init(allocator);
    defer instance.deinit();
}
