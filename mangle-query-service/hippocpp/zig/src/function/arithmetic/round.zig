//! RoundFunction
const std = @import("std");

pub const RoundFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) RoundFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *RoundFunction) void {
        _ = self;
    }
};

test "RoundFunction" {
    const allocator = std.testing.allocator;
    var instance = RoundFunction.init(allocator);
    defer instance.deinit();
}
