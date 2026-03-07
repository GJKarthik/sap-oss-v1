//! SqrtFunction
const std = @import("std");

pub const SqrtFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) SqrtFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *SqrtFunction) void {
        _ = self;
    }
};

test "SqrtFunction" {
    const allocator = std.testing.allocator;
    var instance = SqrtFunction.init(allocator);
    defer instance.deinit();
}
