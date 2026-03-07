//! Path property probing over compact key-value encoded strings.

const std = @import("std");

pub fn probe(encoded: []const u8, key: []const u8) ?[]const u8 {
    var item_it = std.mem.splitScalar(u8, encoded, ';');
    while (item_it.next()) |item| {
        var kv = std.mem.splitScalar(u8, item, '=');
        const k = kv.next() orelse continue;
        const v = kv.next() orelse continue;
        if (std.mem.eql(u8, k, key)) return v;
    }
    return null;
}

test "path property probe" {
    const value = probe("len=3;cost=12", "cost");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("12", value.?);
}
