//! Serializer - Binary serialization/deserialization
//!
//! Purpose:
//! Provides binary serialization for database persistence,
//! checkpointing, and network communication.

const std = @import("std");

// ============================================================================
// Serialization Format Constants
// ============================================================================

pub const MAGIC_NUMBER: u32 = 0x4B555A55;  // "KUZU"
pub const VERSION: u32 = 1;

// ============================================================================
// Serializer - Write binary data
// ============================================================================

pub const Serializer = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    position: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator) Serializer {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }
    
    pub fn initWithCapacity(allocator: std.mem.Allocator, capacity: usize) !Serializer {
        var ser = Serializer{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
        };
        try ser.buffer.ensureTotalCapacity(capacity);
        return ser;
    }
    
    pub fn deinit(self: *Serializer) void {
        self.buffer.deinit();
    }
    
    pub fn getBytes(self: *const Serializer) []const u8 {
        return self.buffer.items;
    }
    
    pub fn size(self: *const Serializer) usize {
        return self.buffer.items.len;
    }
    
    pub fn reset(self: *Serializer) void {
        self.buffer.clearRetainingCapacity();
        self.position = 0;
    }
    
    // ========================================================================
    // Primitive Writers
    // ========================================================================
    
    pub fn writeBool(self: *Serializer, value: bool) !void {
        try self.buffer.append(if (value) 1 else 0);
    }
    
    pub fn writeU8(self: *Serializer, value: u8) !void {
        try self.buffer.append(value);
    }
    
    pub fn writeI8(self: *Serializer, value: i8) !void {
        try self.buffer.append(@bitCast(value));
    }
    
    pub fn writeU16(self: *Serializer, value: u16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .little);
        try self.buffer.appendSlice(&bytes);
    }
    
    pub fn writeI16(self: *Serializer, value: i16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(i16, &bytes, value, .little);
        try self.buffer.appendSlice(&bytes);
    }
    
    pub fn writeU32(self: *Serializer, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.buffer.appendSlice(&bytes);
    }
    
    pub fn writeI32(self: *Serializer, value: i32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, value, .little);
        try self.buffer.appendSlice(&bytes);
    }
    
    pub fn writeU64(self: *Serializer, value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.buffer.appendSlice(&bytes);
    }
    
    pub fn writeI64(self: *Serializer, value: i64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, value, .little);
        try self.buffer.appendSlice(&bytes);
    }
    
    pub fn writeF32(self: *Serializer, value: f32) !void {
        try self.buffer.appendSlice(std.mem.asBytes(&value));
    }
    
    pub fn writeF64(self: *Serializer, value: f64) !void {
        try self.buffer.appendSlice(std.mem.asBytes(&value));
    }
    
    // ========================================================================
    // String and Bytes Writers
    // ========================================================================
    
    pub fn writeString(self: *Serializer, value: []const u8) !void {
        try self.writeU32(@intCast(value.len));
        try self.buffer.appendSlice(value);
    }
    
    pub fn writeBytes(self: *Serializer, value: []const u8) !void {
        try self.writeU32(@intCast(value.len));
        try self.buffer.appendSlice(value);
    }
    
    pub fn writeFixedBytes(self: *Serializer, value: []const u8) !void {
        try self.buffer.appendSlice(value);
    }
    
    // ========================================================================
    // Optional and Array Writers
    // ========================================================================
    
    pub fn writeOptional(self: *Serializer, comptime T: type, value: ?T, writeFunc: *const fn (*Serializer, T) anyerror!void) !void {
        if (value) |v| {
            try self.writeBool(true);
            try writeFunc(self, v);
        } else {
            try self.writeBool(false);
        }
    }
    
    pub fn writeArray(self: *Serializer, comptime T: type, values: []const T, writeFunc: *const fn (*Serializer, T) anyerror!void) !void {
        try self.writeU32(@intCast(values.len));
        for (values) |v| {
            try writeFunc(self, v);
        }
    }
    
    // ========================================================================
    // Varint Encoding (for compact integers)
    // ========================================================================
    
    pub fn writeVarint(self: *Serializer, value: u64) !void {
        var v = value;
        while (v >= 0x80) {
            try self.buffer.append(@intCast((v & 0x7F) | 0x80));
            v >>= 7;
        }
        try self.buffer.append(@intCast(v));
    }
    
    pub fn writeSignedVarint(self: *Serializer, value: i64) !void {
        // ZigZag encoding
        const encoded: u64 = @bitCast((value << 1) ^ (value >> 63));
        try self.writeVarint(encoded);
    }
};

// ============================================================================
// Deserializer - Read binary data
// ============================================================================

pub const Deserializer = struct {
    data: []const u8,
    position: usize = 0,
    
    pub fn init(data: []const u8) Deserializer {
        return .{ .data = data };
    }
    
    pub fn remaining(self: *const Deserializer) usize {
        return self.data.len - self.position;
    }
    
    pub fn isAtEnd(self: *const Deserializer) bool {
        return self.position >= self.data.len;
    }
    
    pub fn reset(self: *Deserializer) void {
        self.position = 0;
    }
    
    pub fn skip(self: *Deserializer, count: usize) !void {
        if (self.position + count > self.data.len) return error.EndOfStream;
        self.position += count;
    }
    
    // ========================================================================
    // Primitive Readers
    // ========================================================================
    
    pub fn readBool(self: *Deserializer) !bool {
        if (self.position >= self.data.len) return error.EndOfStream;
        const value = self.data[self.position] != 0;
        self.position += 1;
        return value;
    }
    
    pub fn readU8(self: *Deserializer) !u8 {
        if (self.position >= self.data.len) return error.EndOfStream;
        const value = self.data[self.position];
        self.position += 1;
        return value;
    }
    
    pub fn readI8(self: *Deserializer) !i8 {
        return @bitCast(try self.readU8());
    }
    
    pub fn readU16(self: *Deserializer) !u16 {
        if (self.position + 2 > self.data.len) return error.EndOfStream;
        const value = std.mem.readInt(u16, self.data[self.position..][0..2], .little);
        self.position += 2;
        return value;
    }
    
    pub fn readI16(self: *Deserializer) !i16 {
        if (self.position + 2 > self.data.len) return error.EndOfStream;
        const value = std.mem.readInt(i16, self.data[self.position..][0..2], .little);
        self.position += 2;
        return value;
    }
    
    pub fn readU32(self: *Deserializer) !u32 {
        if (self.position + 4 > self.data.len) return error.EndOfStream;
        const value = std.mem.readInt(u32, self.data[self.position..][0..4], .little);
        self.position += 4;
        return value;
    }
    
    pub fn readI32(self: *Deserializer) !i32 {
        if (self.position + 4 > self.data.len) return error.EndOfStream;
        const value = std.mem.readInt(i32, self.data[self.position..][0..4], .little);
        self.position += 4;
        return value;
    }
    
    pub fn readU64(self: *Deserializer) !u64 {
        if (self.position + 8 > self.data.len) return error.EndOfStream;
        const value = std.mem.readInt(u64, self.data[self.position..][0..8], .little);
        self.position += 8;
        return value;
    }
    
    pub fn readI64(self: *Deserializer) !i64 {
        if (self.position + 8 > self.data.len) return error.EndOfStream;
        const value = std.mem.readInt(i64, self.data[self.position..][0..8], .little);
        self.position += 8;
        return value;
    }
    
    pub fn readF32(self: *Deserializer) !f32 {
        if (self.position + 4 > self.data.len) return error.EndOfStream;
        const value = std.mem.bytesToValue(f32, self.data[self.position..][0..4]);
        self.position += 4;
        return value;
    }
    
    pub fn readF64(self: *Deserializer) !f64 {
        if (self.position + 8 > self.data.len) return error.EndOfStream;
        const value = std.mem.bytesToValue(f64, self.data[self.position..][0..8]);
        self.position += 8;
        return value;
    }
    
    // ========================================================================
    // String and Bytes Readers
    // ========================================================================
    
    pub fn readString(self: *Deserializer) ![]const u8 {
        const len = try self.readU32();
        if (self.position + len > self.data.len) return error.EndOfStream;
        const value = self.data[self.position..self.position + len];
        self.position += len;
        return value;
    }
    
    pub fn readBytes(self: *Deserializer) ![]const u8 {
        return self.readString();
    }
    
    pub fn readFixedBytes(self: *Deserializer, len: usize) ![]const u8 {
        if (self.position + len > self.data.len) return error.EndOfStream;
        const value = self.data[self.position..self.position + len];
        self.position += len;
        return value;
    }
    
    // ========================================================================
    // Varint Decoding
    // ========================================================================
    
    pub fn readVarint(self: *Deserializer) !u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        
        while (true) {
            if (self.position >= self.data.len) return error.EndOfStream;
            const byte = self.data[self.position];
            self.position += 1;
            
            result |= @as(u64, byte & 0x7F) << shift;
            if (byte & 0x80 == 0) break;
            
            shift += 7;
            if (shift >= 64) return error.VarintOverflow;
        }
        
        return result;
    }
    
    pub fn readSignedVarint(self: *Deserializer) !i64 {
        const encoded = try self.readVarint();
        // ZigZag decoding
        return @bitCast((encoded >> 1) ^ (~(encoded & 1) +% 1));
    }
};

// ============================================================================
// Buffer Writer (for file I/O)
// ============================================================================

pub const BufferWriter = struct {
    file: std.fs.File,
    buffer: []u8,
    position: usize = 0,
    bytes_written: u64 = 0,
    
    pub fn init(file: std.fs.File, buffer: []u8) BufferWriter {
        return .{
            .file = file,
            .buffer = buffer,
        };
    }
    
    pub fn flush(self: *BufferWriter) !void {
        if (self.position > 0) {
            try self.file.writeAll(self.buffer[0..self.position]);
            self.bytes_written += self.position;
            self.position = 0;
        }
    }
    
    pub fn write(self: *BufferWriter, data: []const u8) !void {
        var remaining = data;
        
        while (remaining.len > 0) {
            const space = self.buffer.len - self.position;
            const to_copy = @min(space, remaining.len);
            
            @memcpy(self.buffer[self.position..self.position + to_copy], remaining[0..to_copy]);
            self.position += to_copy;
            remaining = remaining[to_copy..];
            
            if (self.position == self.buffer.len) {
                try self.flush();
            }
        }
    }
    
    pub fn writeU64(self: *BufferWriter, value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.write(&bytes);
    }
};

// ============================================================================
// Buffer Reader (for file I/O)
// ============================================================================

pub const BufferReader = struct {
    file: std.fs.File,
    buffer: []u8,
    position: usize = 0,
    valid: usize = 0,
    bytes_read: u64 = 0,
    
    pub fn init(file: std.fs.File, buffer: []u8) BufferReader {
        return .{
            .file = file,
            .buffer = buffer,
        };
    }
    
    fn refill(self: *BufferReader) !void {
        self.valid = try self.file.read(self.buffer);
        self.bytes_read += self.valid;
        self.position = 0;
    }
    
    pub fn read(self: *BufferReader, dest: []u8) !usize {
        var total_read: usize = 0;
        var remaining = dest;
        
        while (remaining.len > 0) {
            if (self.position >= self.valid) {
                try self.refill();
                if (self.valid == 0) break;
            }
            
            const available = self.valid - self.position;
            const to_copy = @min(available, remaining.len);
            
            @memcpy(remaining[0..to_copy], self.buffer[self.position..self.position + to_copy]);
            self.position += to_copy;
            remaining = remaining[to_copy..];
            total_read += to_copy;
        }
        
        return total_read;
    }
    
    pub fn readU64(self: *BufferReader) !u64 {
        var bytes: [8]u8 = undefined;
        const read_count = try self.read(&bytes);
        if (read_count < 8) return error.EndOfStream;
        return std.mem.readInt(u64, &bytes, .little);
    }
};

// ============================================================================
// Checksum Utilities
// ============================================================================

pub const Checksum = struct {
    pub fn crc32(data: []const u8) u32 {
        return std.hash.Crc32.hash(data);
    }
    
    pub fn xxhash64(data: []const u8) u64 {
        return std.hash.XxHash64.hash(0, data);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "serializer primitives" {
    const allocator = std.testing.allocator;
    
    var ser = Serializer.init(allocator);
    defer ser.deinit();
    
    try ser.writeBool(true);
    try ser.writeU8(42);
    try ser.writeI32(-1000);
    try ser.writeU64(0x123456789ABCDEF0);
    try ser.writeF64(3.14159);
    
    var deser = Deserializer.init(ser.getBytes());
    
    try std.testing.expect(try deser.readBool());
    try std.testing.expectEqual(@as(u8, 42), try deser.readU8());
    try std.testing.expectEqual(@as(i32, -1000), try deser.readI32());
    try std.testing.expectEqual(@as(u64, 0x123456789ABCDEF0), try deser.readU64());
    try std.testing.expectApproxEqAbs(@as(f64, 3.14159), try deser.readF64(), 0.00001);
}

test "serializer strings" {
    const allocator = std.testing.allocator;
    
    var ser = Serializer.init(allocator);
    defer ser.deinit();
    
    try ser.writeString("Hello, World!");
    try ser.writeString("");
    try ser.writeString("Zig 🚀");
    
    var deser = Deserializer.init(ser.getBytes());
    
    try std.testing.expectEqualStrings("Hello, World!", try deser.readString());
    try std.testing.expectEqualStrings("", try deser.readString());
    try std.testing.expectEqualStrings("Zig 🚀", try deser.readString());
}

test "serializer varint" {
    const allocator = std.testing.allocator;
    
    var ser = Serializer.init(allocator);
    defer ser.deinit();
    
    try ser.writeVarint(0);
    try ser.writeVarint(127);
    try ser.writeVarint(128);
    try ser.writeVarint(16383);
    try ser.writeVarint(0xFFFFFFFFFFFFFFFF);
    
    var deser = Deserializer.init(ser.getBytes());
    
    try std.testing.expectEqual(@as(u64, 0), try deser.readVarint());
    try std.testing.expectEqual(@as(u64, 127), try deser.readVarint());
    try std.testing.expectEqual(@as(u64, 128), try deser.readVarint());
    try std.testing.expectEqual(@as(u64, 16383), try deser.readVarint());
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), try deser.readVarint());
}

test "serializer signed varint" {
    const allocator = std.testing.allocator;
    
    var ser = Serializer.init(allocator);
    defer ser.deinit();
    
    try ser.writeSignedVarint(0);
    try ser.writeSignedVarint(1);
    try ser.writeSignedVarint(-1);
    try ser.writeSignedVarint(100);
    try ser.writeSignedVarint(-100);
    
    var deser = Deserializer.init(ser.getBytes());
    
    try std.testing.expectEqual(@as(i64, 0), try deser.readSignedVarint());
    try std.testing.expectEqual(@as(i64, 1), try deser.readSignedVarint());
    try std.testing.expectEqual(@as(i64, -1), try deser.readSignedVarint());
    try std.testing.expectEqual(@as(i64, 100), try deser.readSignedVarint());
    try std.testing.expectEqual(@as(i64, -100), try deser.readSignedVarint());
}

test "deserializer end of stream" {
    var deser = Deserializer.init(&[_]u8{ 0x01, 0x02 });
    
    _ = try deser.readU8();
    _ = try deser.readU8();
    
    try std.testing.expectError(error.EndOfStream, deser.readU8());
}

test "checksum" {
    const data = "Hello, World!";
    
    const crc = Checksum.crc32(data);
    try std.testing.expect(crc != 0);
    
    const xxh = Checksum.xxhash64(data);
    try std.testing.expect(xxh != 0);
}