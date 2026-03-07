//! NullIfFunction
const std = @import("std");

pub const NullIfFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) NullIfFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *NullIfFunction) void {
        _ = self;
    }
};

test "NullIfFunction" {
    const allocator = std.testing.allocator;
    var instance = NullIfFunction.init(allocator);
    defer instance.deinit();
}
