//! INSTALL EXTENSION operator support.

const std = @import("std");

pub const InstallRequest = struct {
    extension_name: []const u8,
    source_url: ?[]const u8 = null,
};

pub fn validateInstallRequest(req: InstallRequest) !void {
    if (req.extension_name.len == 0) return error.InvalidExtensionName;
    for (req.extension_name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) {
            return error.InvalidExtensionName;
        }
    }
}

test "validate extension install request" {
    try validateInstallRequest(.{ .extension_name = "vector" });
}
