//! EXPORT DATABASE operator support.

const std = @import("std");

pub const ExportPlan = struct {
    target_dir: []const u8,
    include_wal: bool = true,
};

pub fn buildManifestPath(allocator: std.mem.Allocator, target_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/export-manifest.json", .{std.mem.trimRight(u8, target_dir, "/")});
}

test "build export manifest path" {
    const allocator = std.testing.allocator;
    const path = try buildManifestPath(allocator, "/tmp/out/");
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "export-manifest.json"));
}
