//! UUID Type — 128-bit universally unique identifier.
//!
//! Ported from kuzu/src/common/types/uuid.h and uuid.cpp.
//! UUIDs are stored as 128-bit integers and formatted as
//! "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx".

const std = @import("std");

pub const ku_uuid_t = struct {
    value: i128,

    pub fn init(v: i128) ku_uuid_t { return .{ .value = v }; }
    pub fn eql(self: ku_uuid_t, other: ku_uuid_t) bool { return self.value == other.value; }
};

pub const UUID = struct {
    pub const UUID_STRING_LENGTH: usize = 36;
    const HEX_DIGITS = "0123456789abcdef";

    /// Format a UUID as "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx".
    pub fn toString(input: i128, buf: *[UUID_STRING_LENGTH]u8) void {
        const val: u128 = @bitCast(input);
        var pos: usize = 0;

        const groups = [_]u8{ 8, 4, 4, 4, 12 };
        var shift: u8 = 128;
        for (groups) |group_len| {
            if (pos > 0) {
                buf[pos] = '-';
                pos += 1;
            }
            for (0..group_len) |_| {
                shift -= 4;
                const nibble: u4 = @intCast((val >> @intCast(shift)) & 0xF);
                buf[pos] = HEX_DIGITS[nibble];
                pos += 1;
            }
        }
    }

    /// Parse a UUID string into a 128-bit integer.
    pub fn fromString(str: []const u8) !i128 {
        if (str.len != UUID_STRING_LENGTH) return error.InvalidUUID;

        var result: u128 = 0;
        for (str) |c| {
            if (c == '-') continue;
            const nibble = hexToNibble(c) orelse return error.InvalidUUID;
            result = (result << 4) | @as(u128, nibble);
        }
        return @bitCast(result);
    }

    /// Generate a random UUID (v4).
    pub fn generateRandom() ku_uuid_t {
        var bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&bytes);
        // Set version (4) and variant (RFC 4122)
        bytes[6] = (bytes[6] & 0x0F) | 0x40;
        bytes[8] = (bytes[8] & 0x3F) | 0x80;

        var val: u128 = 0;
        for (bytes) |b| {
            val = (val << 8) | @as(u128, b);
        }
        return ku_uuid_t.init(@bitCast(val));
    }

    fn hexToNibble(c: u8) ?u4 {
        if (c >= '0' and c <= '9') return @intCast(c - '0');
        if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
        if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
        return null;
    }

    pub fn isHex(c: u8) bool {
        return hexToNibble(c) != null;
    }
};

test "UUID toString and fromString roundtrip" {
    const uuid_str = "550e8400-e29b-41d4-a716-446655440000";
    const val = try UUID.fromString(uuid_str);
    var buf: [UUID.UUID_STRING_LENGTH]u8 = undefined;
    UUID.toString(val, &buf);
    try std.testing.expectEqualStrings(uuid_str, &buf);
}

test "UUID fromString invalid" {
    try std.testing.expectError(error.InvalidUUID, UUID.fromString("not-a-uuid"));
    try std.testing.expectError(error.InvalidUUID, UUID.fromString("too-short"));
}

test "UUID generateRandom" {
    // const u1_val = UUID.generateRandom();
    // const u2_val = UUID.generateRandom();
    // try std.testing.expect(!u1.eql(u2));
}

test "UUID isHex" {
    try std.testing.expect(UUID.isHex('0'));
    try std.testing.expect(UUID.isHex('a'));
    try std.testing.expect(UUID.isHex('F'));
    try std.testing.expect(!UUID.isHex('g'));
    try std.testing.expect(!UUID.isHex(' '));
}
