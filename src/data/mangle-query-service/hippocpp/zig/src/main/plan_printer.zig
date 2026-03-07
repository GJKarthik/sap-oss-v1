//! PlanPrinter
const std = @import("std");

pub const PlanPrinter = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) PlanPrinter {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *PlanPrinter) void {
        _ = self;
    }
};

test "PlanPrinter" {
    const allocator = std.testing.allocator;
    var instance = PlanPrinter.init(allocator);
    defer instance.deinit();
}
