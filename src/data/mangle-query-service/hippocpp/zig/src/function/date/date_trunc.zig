//! DateTruncFunction
const std = @import("std");

pub const DateTruncFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) DateTruncFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *DateTruncFunction) void {
        _ = self;
    }
};

test "DateTruncFunction" {
    const allocator = std.testing.allocator;
    var instance = DateTruncFunction.init(allocator);
    defer instance.deinit();
}
