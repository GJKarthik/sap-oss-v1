//! ExportDB
const std = @import("std");

pub const ExportDB = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ExportDB {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ExportDB) void {
        _ = self;
    }
};

test "ExportDB" {
    const allocator = std.testing.allocator;
    var instance = ExportDB.init(allocator);
    defer instance.deinit();
}
