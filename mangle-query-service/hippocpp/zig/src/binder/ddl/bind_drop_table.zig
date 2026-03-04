//! BindDropTable
const std = @import("std");

pub const BindDropTable = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BindDropTable {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BindDropTable) void {
        _ = self;
    }
};

test "BindDropTable" {
    const allocator = std.testing.allocator;
    var instance = BindDropTable.init(allocator);
    defer instance.deinit();
}
