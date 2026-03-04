//! Warning context for query execution.

const std = @import("std");

pub const WarningContext = struct {
    allocator: std.mem.Allocator,
    warnings: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) WarningContext {
        return .{
            .allocator = allocator,
            .warnings = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *WarningContext) void {
        self.warnings.deinit();
    }

    pub fn add(self: *WarningContext, warning: []const u8) !void {
        try self.warnings.append(warning);
    }

    pub fn count(self: *const WarningContext) usize {
        return self.warnings.items.len;
    }

    pub fn clear(self: *WarningContext) void {
        self.warnings.clearRetainingCapacity();
    }
};

test "warning context add and clear" {
    const allocator = std.testing.allocator;
    var ctx = WarningContext.init(allocator);
    defer ctx.deinit();

    try ctx.add("warn1");
    try ctx.add("warn2");
    try std.testing.expectEqual(@as(usize, 2), ctx.count());

    ctx.clear();
    try std.testing.expectEqual(@as(usize, 0), ctx.count());
}
