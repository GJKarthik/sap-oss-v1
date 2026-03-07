//! Profile
const std = @import("std");

pub const Profile = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Profile {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Profile) void {
        _ = self;
    }
};

test "Profile" {
    const allocator = std.testing.allocator;
    var instance = Profile.init(allocator);
    defer instance.deinit();
}
