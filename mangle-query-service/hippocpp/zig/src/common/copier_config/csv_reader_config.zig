//! CSVReaderConfig
const std = @import("std");

pub const CSVReaderConfig = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) CSVReaderConfig {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *CSVReaderConfig) void {
        _ = self;
    }
};

test "CSVReaderConfig" {
    const allocator = std.testing.allocator;
    var instance = CSVReaderConfig.init(allocator);
    defer instance.deinit();
}
