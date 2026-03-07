//! AuxiliaryBuffer
const std = @import("std");

pub const AuxiliaryBuffer = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AuxiliaryBuffer {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AuxiliaryBuffer) void {
        _ = self;
    }
};

test "AuxiliaryBuffer" {
    const allocator = std.testing.allocator;
    var instance = AuxiliaryBuffer.init(allocator);
    defer instance.deinit();
}
