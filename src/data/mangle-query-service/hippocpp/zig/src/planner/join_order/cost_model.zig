//! CostModel
const std = @import("std");

pub const CostModel = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) CostModel {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *CostModel) void {
        _ = self;
    }
};

test "CostModel" {
    const allocator = std.testing.allocator;
    var instance = CostModel.init(allocator);
    defer instance.deinit();
}
