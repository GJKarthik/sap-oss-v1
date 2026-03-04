//! PlanSubquery
const std = @import("std");

pub const PlanSubquery = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) PlanSubquery {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *PlanSubquery) void {
        _ = self;
    }
};

test "PlanSubquery" {
    const allocator = std.testing.allocator;
    var instance = PlanSubquery.init(allocator);
    defer instance.deinit();
}
