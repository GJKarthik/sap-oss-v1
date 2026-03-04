//! FSST
const std = @import("std");

pub const FSST = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) FSST {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *FSST) void {
        _ = self;
    }
};

test "FSST" {
    const allocator = std.testing.allocator;
    var instance = FSST.init(allocator);
    defer instance.deinit();
}
