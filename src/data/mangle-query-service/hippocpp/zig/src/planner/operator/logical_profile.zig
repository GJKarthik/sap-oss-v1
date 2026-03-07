//! LogicalProfile
const std = @import("std");

pub const LogicalProfile = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LogicalProfile {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LogicalProfile) void {
        _ = self;
    }
};

test "LogicalProfile" {
    const allocator = std.testing.allocator;
    var instance = LogicalProfile.init(allocator);
    defer instance.deinit();
}
