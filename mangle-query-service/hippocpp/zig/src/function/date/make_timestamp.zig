//! MakeTimestampFunction
const std = @import("std");

pub const MakeTimestampFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MakeTimestampFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *MakeTimestampFunction) void {
        _ = self;
    }
};

test "MakeTimestampFunction" {
    const allocator = std.testing.allocator;
    var instance = MakeTimestampFunction.init(allocator);
    defer instance.deinit();
}
