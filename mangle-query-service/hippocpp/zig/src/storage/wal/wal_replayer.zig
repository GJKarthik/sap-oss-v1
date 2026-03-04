//! WALReplayer
const std = @import("std");

pub const WALReplayer = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) WALReplayer {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *WALReplayer) void {
        _ = self;
    }
};

test "WALReplayer" {
    const allocator = std.testing.allocator;
    var instance = WALReplayer.init(allocator);
    defer instance.deinit();
}
