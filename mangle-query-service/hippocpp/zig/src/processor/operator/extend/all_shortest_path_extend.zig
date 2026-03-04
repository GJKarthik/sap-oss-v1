//! AllShortestPathExtend
const std = @import("std");

pub const AllShortestPathExtend = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AllShortestPathExtend {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AllShortestPathExtend) void {
        _ = self;
    }
};

test "AllShortestPathExtend" {
    const allocator = std.testing.allocator;
    var instance = AllShortestPathExtend.init(allocator);
    defer instance.deinit();
}
