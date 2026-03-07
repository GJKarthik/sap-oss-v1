//! PlanUpdate
const std = @import("std");

pub const PlanUpdate = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) PlanUpdate {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *PlanUpdate) void {
        _ = self;
    }
};

test "PlanUpdate" {
    const allocator = std.testing.allocator;
    var instance = PlanUpdate.init(allocator);
    defer instance.deinit();
}
