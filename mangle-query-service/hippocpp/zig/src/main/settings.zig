//! Settings
const std = @import("std");

pub const Settings = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Settings {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Settings) void {
        _ = self;
    }
};

test "Settings" {
    const allocator = std.testing.allocator;
    var instance = Settings.init(allocator);
    defer instance.deinit();
}
