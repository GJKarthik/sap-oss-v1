//! CoalesceFunction
const std = @import("std");

pub const CoalesceFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) CoalesceFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *CoalesceFunction) void {
        _ = self;
    }
};

test "CoalesceFunction" {
    const allocator = std.testing.allocator;
    var instance = CoalesceFunction.init(allocator);
    defer instance.deinit();
}
