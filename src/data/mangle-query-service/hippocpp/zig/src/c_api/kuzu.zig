//! KuzuCAPI
const std = @import("std");

pub const KuzuCAPI = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) KuzuCAPI {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *KuzuCAPI) void {
        _ = self;
    }
};

test "KuzuCAPI" {
    const allocator = std.testing.allocator;
    var instance = KuzuCAPI.init(allocator);
    defer instance.deinit();
}
