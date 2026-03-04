//! MakeDateFunction
const std = @import("std");

pub const MakeDateFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MakeDateFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *MakeDateFunction) void {
        _ = self;
    }
};

test "MakeDateFunction" {
    const allocator = std.testing.allocator;
    var instance = MakeDateFunction.init(allocator);
    defer instance.deinit();
}
