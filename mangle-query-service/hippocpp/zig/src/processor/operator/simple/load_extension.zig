//! LOAD EXTENSION operator support.

const std = @import("std");

pub const LoadedExtension = struct {
    name: []const u8,
    loaded_at_epoch_ms: i64,
};

pub fn load(name: []const u8) !LoadedExtension {
    if (name.len == 0) return error.InvalidExtensionName;
    return .{
        .name = name,
        .loaded_at_epoch_ms = std.time.milliTimestamp(),
    };
}

test "load extension" {
    const ext = try load("json");
    try std.testing.expectEqualStrings("json", ext.name);
}
