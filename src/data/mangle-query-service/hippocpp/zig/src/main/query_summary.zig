//! QuerySummary
const std = @import("std");

pub const QuerySummary = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) QuerySummary {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *QuerySummary) void {
        _ = self;
    }
};

test "QuerySummary" {
    const allocator = std.testing.allocator;
    var instance = QuerySummary.init(allocator);
    defer instance.deinit();
}
