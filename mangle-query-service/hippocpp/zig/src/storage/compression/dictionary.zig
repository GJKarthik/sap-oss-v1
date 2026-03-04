//! Dictionary
const std = @import("std");

pub const Dictionary = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Dictionary {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Dictionary) void {
        _ = self;
    }
};

test "Dictionary" {
    const allocator = std.testing.allocator;
    var instance = Dictionary.init(allocator);
    defer instance.deinit();
}
