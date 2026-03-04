//! FactorizationRewriter
const std = @import("std");

pub const FactorizationRewriter = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) FactorizationRewriter {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *FactorizationRewriter) void {
        _ = self;
    }
};

test "FactorizationRewriter" {
    const allocator = std.testing.allocator;
    var instance = FactorizationRewriter.init(allocator);
    defer instance.deinit();
}
