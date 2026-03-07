//! CommentOn
const std = @import("std");

pub const CommentOn = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) CommentOn {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *CommentOn) void {
        _ = self;
    }
};

test "CommentOn" {
    const allocator = std.testing.allocator;
    var instance = CommentOn.init(allocator);
    defer instance.deinit();
}
