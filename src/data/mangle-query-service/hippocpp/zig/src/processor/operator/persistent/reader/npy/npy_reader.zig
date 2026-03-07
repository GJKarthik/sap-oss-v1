//! Minimal NPY header parser.

const std = @import("std");

pub const NpyHeader = struct {
    version_major: u8,
    version_minor: u8,
};

pub fn parseHeader(bytes: []const u8) !NpyHeader {
    if (bytes.len < 8) return error.InvalidHeader;
    if (!std.mem.eql(u8, bytes[0..6], "\x93NUMPY")) return error.InvalidMagic;
    return .{ .version_major = bytes[6], .version_minor = bytes[7] };
}

test "parse npy header" {
    const header = [_]u8{ 0x93, 'N', 'U', 'M', 'P', 'Y', 1, 0 };
    const parsed = try parseHeader(&header);
    try std.testing.expectEqual(@as(u8, 1), parsed.version_major);
}
