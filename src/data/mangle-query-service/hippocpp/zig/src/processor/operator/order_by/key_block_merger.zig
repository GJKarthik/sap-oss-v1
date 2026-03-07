//! KeyBlockMerger
const std = @import("std");

pub const KeyBlockMerger = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) KeyBlockMerger {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *KeyBlockMerger) void {
        _ = self;
    }
};

test "KeyBlockMerger" {
    const allocator = std.testing.allocator;
    var instance = KeyBlockMerger.init(allocator);
    defer instance.deinit();
}
