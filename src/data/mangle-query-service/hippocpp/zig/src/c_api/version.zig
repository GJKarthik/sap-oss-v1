//! C API version helpers.

const std = @import("std");
const c_helpers = @import("helpers.zig");
const main_version = @import("../main/version.zig");

pub fn getVersionCString() ?[*:0]u8 {
    return c_helpers.convertToOwnedCString(main_version.getVersion());
}

pub fn getStorageVersion() u64 {
    return main_version.getStorageVersion();
}

test "version c api" {
    const v = getVersionCString() orelse return error.OutOfMemory;
    defer c_helpers.freeOwnedCString(v);

    try std.testing.expect(std.mem.eql(u8, std.mem.span(v), main_version.getVersion()));
    try std.testing.expectEqual(main_version.getStorageVersion(), getStorageVersion());
}
