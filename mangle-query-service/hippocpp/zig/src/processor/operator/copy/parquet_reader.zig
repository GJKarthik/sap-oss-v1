//! ParquetReader
const std = @import("std");

pub const ParquetReader = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ParquetReader {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ParquetReader) void {
        _ = self;
    }
};

test "ParquetReader" {
    const allocator = std.testing.allocator;
    var instance = ParquetReader.init(allocator);
    defer instance.deinit();
}
