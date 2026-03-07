//! ShadowFile
const std = @import("std");

pub const ShadowFile = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ShadowFile {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ShadowFile) void {
        _ = self;
    }
};

test "ShadowFile" {
    const allocator = std.testing.allocator;
    var instance = ShadowFile.init(allocator);
    defer instance.deinit();
}
