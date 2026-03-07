//! QueryResultC
const std = @import("std");

pub const QueryResultC = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) QueryResultC {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *QueryResultC) void {
        _ = self;
    }
};

test "QueryResultC" {
    const allocator = std.testing.allocator;
    var instance = QueryResultC.init(allocator);
    defer instance.deinit();
}
