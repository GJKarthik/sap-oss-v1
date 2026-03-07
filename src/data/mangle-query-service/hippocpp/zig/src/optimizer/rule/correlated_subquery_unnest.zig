//! CorrelatedSubqueryUnnest
const std = @import("std");

pub const CorrelatedSubqueryUnnest = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) CorrelatedSubqueryUnnest {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *CorrelatedSubqueryUnnest) void {
        _ = self;
    }
};

test "CorrelatedSubqueryUnnest" {
    const allocator = std.testing.allocator;
    var instance = CorrelatedSubqueryUnnest.init(allocator);
    defer instance.deinit();
}
