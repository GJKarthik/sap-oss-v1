//! CSVReader
const std = @import("std");

pub const CSVReader = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) CSVReader {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *CSVReader) void {
        _ = self;
    }
};

test "CSVReader" {
    const allocator = std.testing.allocator;
    var instance = CSVReader.init(allocator);
    defer instance.deinit();
}
