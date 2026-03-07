//! FTSExtension
const std = @import("std");

pub const FTSExtension = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) FTSExtension {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *FTSExtension) void {
        _ = self;
    }
};

test "FTSExtension" {
    const allocator = std.testing.allocator;
    var instance = FTSExtension.init(allocator);
    defer instance.deinit();
}
