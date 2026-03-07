//! MetadataDAHInfo
const std = @import("std");

pub const MetadataDAHInfo = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MetadataDAHInfo {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *MetadataDAHInfo) void {
        _ = self;
    }
};

test "MetadataDAHInfo" {
    const allocator = std.testing.allocator;
    var instance = MetadataDAHInfo.init(allocator);
    defer instance.deinit();
}
