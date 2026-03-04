//! WALRecordBuilder
const std = @import("std");

pub const WALRecordBuilder = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) WALRecordBuilder {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *WALRecordBuilder) void {
        _ = self;
    }
};

test "WALRecordBuilder" {
    const allocator = std.testing.allocator;
    var instance = WALRecordBuilder.init(allocator);
    defer instance.deinit();
}
