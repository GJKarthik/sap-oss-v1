//! TableSchema
const std = @import("std");

pub const TableSchema = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TableSchema {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *TableSchema) void {
        _ = self;
    }
};

test "TableSchema" {
    const allocator = std.testing.allocator;
    var instance = TableSchema.init(allocator);
    defer instance.deinit();
}
