//! Blob and UUID Types - Binary data types
//!
//! Purpose:
//! Provides blob (binary large object) and UUID types
//! with encoding, parsing, and comparison operations.

const std = @import("std");

// ============================================================================
// Blob Type
// ============================================================================

pub const Blob = struct {
    allocator: ?std.mem.Allocator,
    data: []const u8,
    owned: bool = false,
    
    pub fn init(data: []const u8) Blob {
        return .{
            .allocator = null,
            .data = data,
            .owned = false,
        };
    }
    
    pub fn initOwned(allocator: std.mem.Allocator, data: []const u8) !Blob {
        return .{
            .allocator = allocator,
            .data = try allocator.dupe(u8, data),
            .owned = true,
        };
    }
    
    pub fn initEmpty() Blob {
        return .{
            .allocator = null,
            .data = &[_]u8{},
            .owned = false,
        };
    }
    
    pub fn deinit(self: *Blob) void {
        if (self.owned) {
            if (self.allocator) |alloc| {
                alloc.free(self.data);
            }
        }
    }
    
    pub fn len(self: *const Blob) usize {
        return self.data.len;
    }
    
    pub fn isEmpty(self: *const Blob) bool {
        return self.data.len == 0;
    }
    
    pub fn eql(self: *const Blob, other: *const Blob) bool {
        return std.mem.eql(u8, self.data, other.data);
    }
    
    pub fn compare(self: *const Blob, other: *const Blob) std.math.Order {
        return std.mem.order(u8, self.data, other.data);
    }
    
    pub fn hash(self: *const Blob) u64 {
        return std.hash.XxHash64.hash(0, self.data);
    }
    
    /// Convert to hex string
    pub fn toHex(self: *const Blob, allocator: std.mem.Allocator) ![]u8 {
        const hex_chars = "0123456789abcdef";
        var result = try allocator.alloc(u8, self.data.len * 2);
        
        for (self.data, 0..) |byte, i| {
            result[i * 2] = hex_chars[byte >> 4];
            result[i * 2 + 1] = hex_chars[byte & 0x0f];
        }
        
        return result;
    }
    
    /// Parse from hex string
    pub fn fromHex(allocator: std.mem.Allocator, hex: []const u8) !Blob {
        if (hex.len % 2 != 0) return error.InvalidHexLength;
        
        var data = try allocator.alloc(u8, hex.len / 2);
        errdefer allocator.free(data);
        
        var i: usize = 0;
        while (i < hex.len) : (i += 2) {
            const high = try hexCharToValue(hex[i]);
            const low = try hexCharToValue(hex[i + 1]);
            data[i / 2] = (high << 4) | low;
        }
        
        return .{
            .allocator = allocator,
            .data = data,
            .owned = true,
        };
    }
    
    fn hexCharToValue(c: u8) !u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => error.InvalidHexChar,
        };
    }
    
    /// Convert to base64
    pub fn toBase64(self: *const Blob, allocator: std.mem.Allocator) ![]u8 {
        const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        const output_len = ((self.data.len + 2) / 3) * 4;
        var result = try allocator.alloc(u8, output_len);
        
        var i: usize = 0;
        var j: usize = 0;
        while (i < self.data.len) {
            const b0 = self.data[i];
            const b1 = if (i + 1 < self.data.len) self.data[i + 1] else 0;
            const b2 = if (i + 2 < self.data.len) self.data[i + 2] else 0;
            
            result[j] = alphabet[b0 >> 2];
            result[j + 1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
            result[j + 2] = if (i + 1 < self.data.len) alphabet[((b1 & 0x0f) << 2) | (b2 >> 6)] else '=';
            result[j + 3] = if (i + 2 < self.data.len) alphabet[b2 & 0x3f] else '=';
            
            i += 3;
            j += 4;
        }
        
        return result;
    }
};

// ============================================================================
// UUID Type (128-bit universally unique identifier)
// ============================================================================

pub const UUID = struct {
    bytes: [16]u8,
    
    pub const NIL = UUID{ .bytes = [_]u8{0} ** 16 };
    
    pub fn init(bytes: [16]u8) UUID {
        return .{ .bytes = bytes };
    }
    
    /// Generate UUID v4 (random)
    pub fn v4() UUID {
        var bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&bytes);
        
        // Set version to 4
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        // Set variant to RFC 4122
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        
        return .{ .bytes = bytes };
    }
    
    /// Parse from string "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    pub fn parse(str: []const u8) !UUID {
        if (str.len != 36) return error.InvalidUUIDLength;
        
        // Validate format: 8-4-4-4-12 with dashes
        if (str[8] != '-' or str[13] != '-' or str[18] != '-' or str[23] != '-') {
            return error.InvalidUUIDFormat;
        }
        
        var bytes: [16]u8 = undefined;
        var byte_idx: usize = 0;
        
        const segments = [_]struct { start: usize, end: usize }{
            .{ .start = 0, .end = 8 },
            .{ .start = 9, .end = 13 },
            .{ .start = 14, .end = 18 },
            .{ .start = 19, .end = 23 },
            .{ .start = 24, .end = 36 },
        };
        
        for (segments) |seg| {
            var i = seg.start;
            while (i < seg.end) : (i += 2) {
                const high = try hexCharToValue(str[i]);
                const low = try hexCharToValue(str[i + 1]);
                bytes[byte_idx] = (high << 4) | low;
                byte_idx += 1;
            }
        }
        
        return .{ .bytes = bytes };
    }
    
    fn hexCharToValue(c: u8) !u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => error.InvalidHexChar,
        };
    }
    
    /// Format to string "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    pub fn format(self: *const UUID, buf: *[36]u8) void {
        const hex = "0123456789abcdef";
        
        var buf_idx: usize = 0;
        for (self.bytes, 0..) |byte, i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                buf[buf_idx] = '-';
                buf_idx += 1;
            }
            buf[buf_idx] = hex[byte >> 4];
            buf[buf_idx + 1] = hex[byte & 0x0f];
            buf_idx += 2;
        }
    }
    
    pub fn toString(self: *const UUID) [36]u8 {
        var buf: [36]u8 = undefined;
        self.format(&buf);
        return buf;
    }
    
    pub fn eql(self: *const UUID, other: *const UUID) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
    
    pub fn compare(self: *const UUID, other: *const UUID) std.math.Order {
        return std.mem.order(u8, &self.bytes, &other.bytes);
    }
    
    pub fn hash(self: *const UUID) u64 {
        return std.hash.XxHash64.hash(0, &self.bytes);
    }
    
    pub fn isNil(self: *const UUID) bool {
        return self.eql(&NIL);
    }
    
    /// Get version (4 bits)
    pub fn version(self: *const UUID) u8 {
        return self.bytes[6] >> 4;
    }
    
    /// Get variant
    pub fn variant(self: *const UUID) u8 {
        return self.bytes[8] >> 6;
    }
};

// ============================================================================
// Binary String (length-prefixed)
// ============================================================================

pub const BinaryString = struct {
    data: []const u8,
    
    pub const MAX_LENGTH: usize = 65535;
    
    pub fn init(data: []const u8) !BinaryString {
        if (data.len > MAX_LENGTH) return error.StringTooLong;
        return .{ .data = data };
    }
    
    pub fn len(self: *const BinaryString) usize {
        return self.data.len;
    }
    
    pub fn eql(self: *const BinaryString, other: *const BinaryString) bool {
        return std.mem.eql(u8, self.data, other.data);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "blob basic" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const blob = Blob.init(&data);
    
    try std.testing.expectEqual(@as(usize, 4), blob.len());
    try std.testing.expect(!blob.isEmpty());
}

test "blob empty" {
    const blob = Blob.initEmpty();
    try std.testing.expect(blob.isEmpty());
}

test "blob hex conversion" {
    const allocator = std.testing.allocator;
    
    var blob = try Blob.fromHex(allocator, "deadbeef");
    defer blob.deinit();
    
    try std.testing.expectEqual(@as(usize, 4), blob.len());
    try std.testing.expectEqual(@as(u8, 0xde), blob.data[0]);
    try std.testing.expectEqual(@as(u8, 0xad), blob.data[1]);
    try std.testing.expectEqual(@as(u8, 0xbe), blob.data[2]);
    try std.testing.expectEqual(@as(u8, 0xef), blob.data[3]);
    
    const hex = try blob.toHex(allocator);
    defer allocator.free(hex);
    try std.testing.expectEqualStrings("deadbeef", hex);
}

test "uuid nil" {
    try std.testing.expect(UUID.NIL.isNil());
}

test "uuid v4" {
    const uuid = UUID.v4();
    try std.testing.expect(!uuid.isNil());
    try std.testing.expectEqual(@as(u8, 4), uuid.version());
}

test "uuid parse and format" {
    const uuid = try UUID.parse("550e8400-e29b-41d4-a716-446655440000");
    const str = uuid.toString();
    
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", &str);
}

test "uuid equality" {
    const uuid1 = try UUID.parse("550e8400-e29b-41d4-a716-446655440000");
    const uuid2 = try UUID.parse("550e8400-e29b-41d4-a716-446655440000");
    const uuid3 = try UUID.parse("550e8400-e29b-41d4-a716-446655440001");
    
    try std.testing.expect(uuid1.eql(&uuid2));
    try std.testing.expect(!uuid1.eql(&uuid3));
}

test "blob compare" {
    const data1 = [_]u8{ 0x01, 0x02 };
    const data2 = [_]u8{ 0x01, 0x03 };
    
    const blob1 = Blob.init(&data1);
    const blob2 = Blob.init(&data2);
    
    try std.testing.expectEqual(std.math.Order.lt, blob1.compare(&blob2));
}

test "binary string" {
    const bs = try BinaryString.init("hello");
    try std.testing.expectEqual(@as(usize, 5), bs.len());
}