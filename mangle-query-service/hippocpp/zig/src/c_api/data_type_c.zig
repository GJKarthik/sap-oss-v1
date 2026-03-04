//! DataTypeC
const std = @import("std");

pub const DataTypeC = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) DataTypeC {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *DataTypeC) void {
        _ = self;
    }
};

test "DataTypeC" {
    const allocator = std.testing.allocator;
    var instance = DataTypeC.init(allocator);
    defer instance.deinit();
}
