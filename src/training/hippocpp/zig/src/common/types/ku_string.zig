//! Kuzu String Type — Short string optimization with overflow pointer.
//!
//! Ported from kuzu/src/common/types/ku_string.h.
//! Strings <= 12 bytes are stored inline (4-byte prefix + 8-byte suffix).
//! Longer strings store a 4-byte prefix + 8-byte overflow pointer.

const std = @import("std");

pub const ku_string_t = struct {
    pub const PREFIX_LENGTH: usize = 4;
    pub const INLINED_SUFFIX_LENGTH: usize = 8;
    pub const SHORT_STR_LENGTH: usize = PREFIX_LENGTH + INLINED_SUFFIX_LENGTH;

    len: u32 = 0,
    prefix: [PREFIX_LENGTH]u8 = .{0} ** PREFIX_LENGTH,
    /// For short strings: inline suffix data. For long strings: overflow pointer.
    data: [INLINED_SUFFIX_LENGTH]u8 = .{0} ** INLINED_SUFFIX_LENGTH,

    const Self = @This();

    pub fn isShortString(length: u32) bool {
        return length <= SHORT_STR_LENGTH;
    }

    /// Get a slice view of the string data.
    pub fn getData(self: *const Self) []const u8 {
        if (isShortString(self.len)) {
            // Short string: data is in prefix + inlined suffix
            const ptr: [*]const u8 = @ptrCast(&self.prefix);
            return ptr[0..self.len];
        } else {
            // Long string: suffix stores a pointer
            const ptr_val = std.mem.readInt(u64, self.data[0..8], .little);
            const ptr: [*]const u8 = @ptrFromInt(ptr_val);
            return ptr[0..self.len];
        }
    }

    /// Set from a byte slice (short strings only).
    pub fn setShort(self: *Self, value: []const u8) void {
        std.debug.assert(value.len <= SHORT_STR_LENGTH);
        self.len = @intCast(value.len);
        const dest: [*]u8 = @ptrCast(&self.prefix);
        @memcpy(dest[0..value.len], value);
    }

    /// Set from a raw pointer (for long strings — stores pointer, copies prefix).
    pub fn setFromRaw(self: *Self, value: [*]const u8, length: u32) void {
        self.len = length;
        @memcpy(&self.prefix, value[0..PREFIX_LENGTH]);
        if (!isShortString(length)) {
            std.mem.writeInt(u64, self.data[0..8], @intFromPtr(value), .little);
        } else {
            const dest: [*]u8 = @ptrCast(&self.prefix);
            @memcpy(dest[0..length], value[0..length]);
        }
    }

    /// Compare two ku_string_t values for equality.
    pub fn eql(self: *const Self, other: *const Self) bool {
        if (self.len != other.len) return false;
        // Quick prefix check
        if (!std.mem.eql(u8, &self.prefix, &other.prefix)) return false;
        if (self.len <= PREFIX_LENGTH) return true;
        // Full comparison
        return std.mem.eql(u8, self.getData(), other.getData());
    }

    /// Lexicographic comparison.
    pub fn lessThan(self: *const Self, other: *const Self) bool {
        // Quick prefix comparison
        const prefix_cmp = std.mem.order(u8, &self.prefix, &other.prefix);
        if (prefix_cmp != .eq) return prefix_cmp == .lt;
        if (self.len <= PREFIX_LENGTH and other.len <= PREFIX_LENGTH) {
            return self.len < other.len;
        }
        // Full comparison
        const self_data = self.getData();
        const other_data = other.getData();
        const cmp = std.mem.order(u8, self_data, other_data);
        return cmp == .lt;
    }

    pub fn greaterThan(self: *const Self, other: *const Self) bool {
        return other.lessThan(self);
    }
};

test "ku_string_t short string" {
    var s = ku_string_t{};
    s.setShort("hello");
    try std.testing.expectEqual(@as(u32, 5), s.len);
    try std.testing.expect(ku_string_t.isShortString(5));

    const data = s.getData();
    try std.testing.expectEqualStrings("hello", data);
}

test "ku_string_t equality" {
    var s1 = ku_string_t{};
    var s2 = ku_string_t{};
    s1.setShort("test");
    s2.setShort("test");
    try std.testing.expect(s1.eql(&s2));

    s2.setShort("other");
    try std.testing.expect(!s1.eql(&s2));
}

test "ku_string_t isShortString" {
    try std.testing.expect(ku_string_t.isShortString(0));
    try std.testing.expect(ku_string_t.isShortString(12));
    try std.testing.expect(!ku_string_t.isShortString(13));
}
