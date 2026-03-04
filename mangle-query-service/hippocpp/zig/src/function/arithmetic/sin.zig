//! SinFunction
const std = @import("std");

pub const SinFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) SinFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *SinFunction) void {
        _ = self;
    }
};

test "SinFunction" {
    const allocator = std.testing.allocator;
    var instance = SinFunction.init(allocator);
    defer instance.deinit();
}
