//! ImportDB
const std = @import("std");

pub const ImportDB = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ImportDB {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ImportDB) void {
        _ = self;
    }
};

test "ImportDB" {
    const allocator = std.testing.allocator;
    var instance = ImportDB.init(allocator);
    defer instance.deinit();
}
