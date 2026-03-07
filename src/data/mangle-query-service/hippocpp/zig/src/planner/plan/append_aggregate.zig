//! AppendAggregate
const std = @import("std");

pub const AppendAggregate = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AppendAggregate {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AppendAggregate) void {
        _ = self;
    }
};

test "AppendAggregate" {
    const allocator = std.testing.allocator;
    var instance = AppendAggregate.init(allocator);
    defer instance.deinit();
}
