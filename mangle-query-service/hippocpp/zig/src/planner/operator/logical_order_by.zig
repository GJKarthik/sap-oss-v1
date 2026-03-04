//! LogicalOrderBy
const std = @import("std");

pub const LogicalOrderBy = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LogicalOrderBy {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LogicalOrderBy) void {
        _ = self;
    }
};

test "LogicalOrderBy" {
    const allocator = std.testing.allocator;
    var instance = LogicalOrderBy.init(allocator);
    defer instance.deinit();
}
