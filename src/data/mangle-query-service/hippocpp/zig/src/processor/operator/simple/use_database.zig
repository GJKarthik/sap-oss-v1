//! USE DATABASE operator support.

const std = @import("std");

pub const UseDatabaseState = struct {
    active_alias: ?[]const u8 = null,

    pub fn setActive(self: *UseDatabaseState, alias: []const u8) !void {
        if (alias.len == 0) return error.InvalidDatabaseAlias;
        self.active_alias = alias;
    }

    pub fn clear(self: *UseDatabaseState) void {
        self.active_alias = null;
    }
};

test "use database state transitions" {
    var state = UseDatabaseState{};
    try state.setActive("analytics");
    try std.testing.expect(state.active_alias != null);
    state.clear();
    try std.testing.expect(state.active_alias == null);
}
