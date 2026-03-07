//! LogicalOperatorVisitor
const std = @import("std");

pub const LogicalOperatorVisitor = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LogicalOperatorVisitor {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LogicalOperatorVisitor) void {
        _ = self;
    }
};

test "LogicalOperatorVisitor" {
    const allocator = std.testing.allocator;
    var instance = LogicalOperatorVisitor.init(allocator);
    defer instance.deinit();
}
