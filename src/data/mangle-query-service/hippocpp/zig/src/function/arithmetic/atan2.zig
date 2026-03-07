//! Atan2Function
const std = @import("std");

pub const Atan2Function = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Atan2Function {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Atan2Function) void {
        _ = self;
    }
};

test "Atan2Function" {
    const allocator = std.testing.allocator;
    var instance = Atan2Function.init(allocator);
    defer instance.deinit();
}
