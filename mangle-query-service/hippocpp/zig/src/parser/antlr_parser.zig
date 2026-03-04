//! AntlrParser
const std = @import("std");

pub const AntlrParser = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AntlrParser {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AntlrParser) void {
        _ = self;
    }
};

test "AntlrParser" {
    const allocator = std.testing.allocator;
    var instance = AntlrParser.init(allocator);
    defer instance.deinit();
}
