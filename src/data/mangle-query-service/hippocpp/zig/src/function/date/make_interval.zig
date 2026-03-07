//! MakeIntervalFunction
const std = @import("std");

pub const MakeIntervalFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MakeIntervalFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *MakeIntervalFunction) void {
        _ = self;
    }
};

test "MakeIntervalFunction" {
    const allocator = std.testing.allocator;
    var instance = MakeIntervalFunction.init(allocator);
    defer instance.deinit();
}
