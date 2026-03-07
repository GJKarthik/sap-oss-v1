//! TanFunction
const std = @import("std");

pub const TanFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TanFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *TanFunction) void {
        _ = self;
    }
};

test "TanFunction" {
    const allocator = std.testing.allocator;
    var instance = TanFunction.init(allocator);
    defer instance.deinit();
}
