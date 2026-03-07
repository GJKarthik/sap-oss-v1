//! AtanFunction
const std = @import("std");

pub const AtanFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AtanFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AtanFunction) void {
        _ = self;
    }
};

test "AtanFunction" {
    const allocator = std.testing.allocator;
    var instance = AtanFunction.init(allocator);
    defer instance.deinit();
}
