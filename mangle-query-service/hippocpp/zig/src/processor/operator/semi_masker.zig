//! SemiMasker
const std = @import("std");

pub const SemiMasker = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) SemiMasker {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *SemiMasker) void {
        _ = self;
    }
};

test "SemiMasker" {
    const allocator = std.testing.allocator;
    var instance = SemiMasker.init(allocator);
    defer instance.deinit();
}
