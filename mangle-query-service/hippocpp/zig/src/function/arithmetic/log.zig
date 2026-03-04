//! LogFunction
const std = @import("std");

pub const LogFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LogFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LogFunction) void {
        _ = self;
    }
};

test "LogFunction" {
    const allocator = std.testing.allocator;
    var instance = LogFunction.init(allocator);
    defer instance.deinit();
}
