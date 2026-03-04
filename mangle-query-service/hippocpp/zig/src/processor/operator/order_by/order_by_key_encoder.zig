//! Stable key encoding helpers for ORDER BY.

const std = @import("std");

pub fn encodeI64(value: i64) [8]u8 {
    // Sign-flip preserves numeric order in lexicographic byte order.
    const biased: u64 = @bitCast(value) ^ 0x8000_0000_0000_0000;
    return std.mem.toBytes(std.mem.nativeToBig(u64, biased));
}

pub fn decodeI64(bytes: [8]u8) i64 {
    const be = std.mem.bytesToValue(u64, &bytes);
    const biased = std.mem.bigToNative(u64, be);
    const raw = biased ^ 0x8000_0000_0000_0000;
    return @bitCast(raw);
}

test "encode decode i64 order key" {
    const v: i64 = -42;
    const enc = encodeI64(v);
    const dec = decodeI64(enc);
    try std.testing.expectEqual(v, dec);
}
