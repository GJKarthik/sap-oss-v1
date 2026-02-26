const std = @import("std");

/// CRC32C (Castagnoli) implementation for Pulsar protocol.
/// Uses the 0x82F63B78 polynomial.
pub const CRC32C = struct {
    table: [256]u32,

    pub fn init() CRC32C {
        var self = CRC32C{ .table = undefined };
        const poly = 0x82F63B78;
        for (0..256) |i| {
            var res = @as(u32, @intCast(i));
            for (0..8) |_| {
                if (res & 1 == 1) {
                    res = (res >> 1) ^ poly;
                } else {
                    res >>= 1;
                }
            }
            self.table[i] = res;
        }
        return self;
    }

    pub fn update(self: *const CRC32C, crc: u32, data: []const u8) u32 {
        var res = ~crc;
        for (data) |byte| {
            res = (res >> 8) ^ self.table[(res ^ byte) & 0xFF];
        }
        return ~res;
    }

    pub fn hash(self: *const CRC32C, data: []const u8) u32 {
        return self.update(0, data);
    }
};

var global_crc32c: ?CRC32C = null;

pub fn getCrc32c() *const CRC32C {
    if (global_crc32c == null) {
        global_crc32c = CRC32C.init();
    }
    return &global_crc32c.?;
}
