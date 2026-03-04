//! Version metadata for the main HippoCPP engine.

const std = @import("std");

pub const VERSION = "1.0.0";
pub const STORAGE_VERSION: u64 = 1;

pub fn getVersion() []const u8 {
    return VERSION;
}

pub fn getStorageVersion() u64 {
    return STORAGE_VERSION;
}

test "version values" {
    try std.testing.expectEqualStrings("1.0.0", getVersion());
    try std.testing.expectEqual(@as(u64, 1), getStorageVersion());
}
