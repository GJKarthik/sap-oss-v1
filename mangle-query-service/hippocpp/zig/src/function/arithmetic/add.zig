//! AddFunction
const std = @import("std");

pub const AddFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AddFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AddFunction) void {
        _ = self;
    }
};

test "AddFunction" {
    const allocator = std.testing.allocator;
    var instance = AddFunction.init(allocator);
    defer instance.deinit();
}
