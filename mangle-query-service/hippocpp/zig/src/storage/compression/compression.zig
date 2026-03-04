//! Compression Framework - Core compression/decompression infrastructure
//!
//! Purpose:
//! Provides compression algorithms for columnar storage including:
//! - Run-length encoding (RLE)
//! - Dictionary encoding
//! - Bit-packing
//! - Delta encoding
//! - Constant compression

const std = @import("std");

// ============================================================================
// Compression Types
// ============================================================================

pub const CompressionType = enum(u8) {
    UNCOMPRESSED = 0,
    CONSTANT = 1,
    RUN_LENGTH = 2,
    DICTIONARY = 3,
    BIT_PACKING = 4,
    DELTA = 5,
    DELTA_OF_DELTA = 6,
    FOR = 7,  // Frame of Reference
    FSST = 8,  // Fast Static Symbol Table (strings)
    ALP = 9,  // Adaptive Lossless floating Point
};

pub const CompressionInfo = struct {
    compression_type: CompressionType,
    uncompressed_size: u64,
    compressed_size: u64,
    num_values: u64,
    metadata_size: u32 = 0,
    
    pub fn compressionRatio(self: CompressionInfo) f64 {
        if (self.compressed_size == 0) return 0.0;
        return @as(f64, @floatFromInt(self.uncompressed_size)) / @as(f64, @floatFromInt(self.compressed_size));
    }
};

// ============================================================================
// Compression Buffer
// ============================================================================

pub const CompressionBuffer = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8),
    info: CompressionInfo,
    
    pub fn init(allocator: std.mem.Allocator, comp_type: CompressionType) CompressionBuffer {
        return .{
            .allocator = allocator,
            .data = std.ArrayList(u8).init(allocator),
            .info = .{
                .compression_type = comp_type,
                .uncompressed_size = 0,
                .compressed_size = 0,
                .num_values = 0,
            },
        };
    }
    
    pub fn deinit(self: *CompressionBuffer) void {
        self.data.deinit();
    }
    
    pub fn reset(self: *CompressionBuffer) void {
        self.data.clearRetainingCapacity();
        self.info.compressed_size = 0;
        self.info.uncompressed_size = 0;
        self.info.num_values = 0;
    }
    
    pub fn getBytes(self: *const CompressionBuffer) []const u8 {
        return self.data.items;
    }
};

// ============================================================================
// Run-Length Encoding
// ============================================================================

pub const RLEEncoder = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) RLEEncoder {
        return .{ .allocator = allocator };
    }
    
    /// Encode integer values using RLE
    pub fn encode(self: *RLEEncoder, values: []const i64) !CompressionBuffer {
        var buffer = CompressionBuffer.init(self.allocator, .RUN_LENGTH);
        errdefer buffer.deinit();
        
        if (values.len == 0) return buffer;
        
        var current_value = values[0];
        var run_length: u32 = 1;
        
        for (values[1..]) |value| {
            if (value == current_value) {
                run_length += 1;
            } else {
                // Write run: value (8 bytes) + length (4 bytes)
                try buffer.data.appendSlice(std.mem.asBytes(&current_value));
                try buffer.data.appendSlice(std.mem.asBytes(&run_length));
                current_value = value;
                run_length = 1;
            }
        }
        
        // Write final run
        try buffer.data.appendSlice(std.mem.asBytes(&current_value));
        try buffer.data.appendSlice(std.mem.asBytes(&run_length));
        
        buffer.info.uncompressed_size = values.len * 8;
        buffer.info.compressed_size = buffer.data.items.len;
        buffer.info.num_values = values.len;
        
        return buffer;
    }
    
    /// Decode RLE compressed data
    pub fn decode(self: *RLEEncoder, compressed: []const u8, num_values: usize) !std.ArrayList(i64) {
        var result = std.ArrayList(i64).init(self.allocator);
        errdefer result.deinit();
        
        var pos: usize = 0;
        var decoded_count: usize = 0;
        
        while (pos < compressed.len and decoded_count < num_values) {
            if (pos + 12 > compressed.len) break;
            
            const value = std.mem.bytesToValue(i64, compressed[pos..][0..8]);
            const run_length = std.mem.bytesToValue(u32, compressed[pos + 8 ..][0..4]);
            
            const count = @min(run_length, @as(u32, @intCast(num_values - decoded_count)));
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                try result.append(value);
            }
            
            decoded_count += count;
            pos += 12;
        }
        
        return result;
    }
};

// ============================================================================
// Dictionary Encoding
// ============================================================================

pub const DictionaryEncoder = struct {
    allocator: std.mem.Allocator,
    dictionary: std.StringHashMap(u32),
    reverse_dict: std.ArrayList([]const u8),
    
    pub fn init(allocator: std.mem.Allocator) DictionaryEncoder {
        return .{
            .allocator = allocator,
            .dictionary = std.StringHashMap(u32).init(allocator),
            .reverse_dict = std.ArrayList([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *DictionaryEncoder) void {
        self.dictionary.deinit();
        self.reverse_dict.deinit();
    }
    
    /// Encode strings using dictionary encoding
    pub fn encode(self: *DictionaryEncoder, values: []const []const u8) !CompressionBuffer {
        var buffer = CompressionBuffer.init(self.allocator, .DICTIONARY);
        errdefer buffer.deinit();
        
        var indices = std.ArrayList(u32).init(self.allocator);
        defer indices.deinit();
        
        var total_uncompressed: usize = 0;
        
        for (values) |value| {
            total_uncompressed += value.len;
            
            if (self.dictionary.get(value)) |idx| {
                try indices.append(idx);
            } else {
                const new_idx: u32 = @intCast(self.reverse_dict.items.len);
                try self.dictionary.put(value, new_idx);
                try self.reverse_dict.append(value);
                try indices.append(new_idx);
            }
        }
        
        // Write dictionary size
        const dict_size: u32 = @intCast(self.reverse_dict.items.len);
        try buffer.data.appendSlice(std.mem.asBytes(&dict_size));
        
        // Write dictionary entries
        for (self.reverse_dict.items) |entry| {
            const len: u32 = @intCast(entry.len);
            try buffer.data.appendSlice(std.mem.asBytes(&len));
            try buffer.data.appendSlice(entry);
        }
        
        // Write indices
        for (indices.items) |idx| {
            try buffer.data.appendSlice(std.mem.asBytes(&idx));
        }
        
        buffer.info.uncompressed_size = total_uncompressed;
        buffer.info.compressed_size = buffer.data.items.len;
        buffer.info.num_values = values.len;
        
        return buffer;
    }
};

// ============================================================================
// Bit-Packing
// ============================================================================

pub const BitPackingEncoder = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BitPackingEncoder {
        return .{ .allocator = allocator };
    }
    
    /// Calculate minimum bits needed for value
    pub fn minBits(value: u64) u8 {
        if (value == 0) return 1;
        return @intCast(64 - @clz(value));
    }
    
    /// Calculate minimum bits for array
    pub fn calcBitWidth(values: []const u64) u8 {
        var max_val: u64 = 0;
        for (values) |v| {
            max_val = @max(max_val, v);
        }
        return minBits(max_val);
    }
    
    /// Encode unsigned integers with bit-packing
    pub fn encode(self: *BitPackingEncoder, values: []const u64) !CompressionBuffer {
        var buffer = CompressionBuffer.init(self.allocator, .BIT_PACKING);
        errdefer buffer.deinit();
        
        if (values.len == 0) return buffer;
        
        const bit_width = calcBitWidth(values);
        
        // Write header: bit_width (1 byte) + num_values (4 bytes)
        try buffer.data.append(bit_width);
        const num_vals: u32 = @intCast(values.len);
        try buffer.data.appendSlice(std.mem.asBytes(&num_vals));
        
        // Pack bits
        var bit_buffer: u64 = 0;
        var bits_in_buffer: u8 = 0;
        
        for (values) |value| {
            bit_buffer |= (value & ((1 << bit_width) - 1)) << bits_in_buffer;
            bits_in_buffer += bit_width;
            
            while (bits_in_buffer >= 8) {
                try buffer.data.append(@truncate(bit_buffer & 0xFF));
                bit_buffer >>= 8;
                bits_in_buffer -= 8;
            }
        }
        
        // Flush remaining bits
        if (bits_in_buffer > 0) {
            try buffer.data.append(@truncate(bit_buffer & 0xFF));
        }
        
        buffer.info.uncompressed_size = values.len * 8;
        buffer.info.compressed_size = buffer.data.items.len;
        buffer.info.num_values = values.len;
        
        return buffer;
    }
    
    /// Decode bit-packed data
    pub fn decode(self: *BitPackingEncoder, compressed: []const u8) !std.ArrayList(u64) {
        var result = std.ArrayList(u64).init(self.allocator);
        errdefer result.deinit();
        
        if (compressed.len < 5) return result;
        
        const bit_width = compressed[0];
        const num_values = std.mem.bytesToValue(u32, compressed[1..5]);
        
        var bit_buffer: u64 = 0;
        var bits_in_buffer: u8 = 0;
        var data_pos: usize = 5;
        var decoded: u32 = 0;
        
        while (decoded < num_values) {
            // Load more bytes
            while (bits_in_buffer < bit_width and data_pos < compressed.len) {
                bit_buffer |= @as(u64, compressed[data_pos]) << bits_in_buffer;
                bits_in_buffer += 8;
                data_pos += 1;
            }
            
            // Extract value
            const mask = (@as(u64, 1) << bit_width) - 1;
            try result.append(bit_buffer & mask);
            bit_buffer >>= bit_width;
            bits_in_buffer -= bit_width;
            decoded += 1;
        }
        
        return result;
    }
};

// ============================================================================
// Delta Encoding
// ============================================================================

pub const DeltaEncoder = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) DeltaEncoder {
        return .{ .allocator = allocator };
    }
    
    /// Encode integers using delta encoding
    pub fn encode(self: *DeltaEncoder, values: []const i64) !CompressionBuffer {
        var buffer = CompressionBuffer.init(self.allocator, .DELTA);
        errdefer buffer.deinit();
        
        if (values.len == 0) return buffer;
        
        // Write first value
        try buffer.data.appendSlice(std.mem.asBytes(&values[0]));
        
        // Write deltas using variable-length encoding
        var prev = values[0];
        for (values[1..]) |value| {
            const delta = value - prev;
            try self.writeVarint(&buffer.data, delta);
            prev = value;
        }
        
        buffer.info.uncompressed_size = values.len * 8;
        buffer.info.compressed_size = buffer.data.items.len;
        buffer.info.num_values = values.len;
        
        return buffer;
    }
    
    fn writeVarint(self: *DeltaEncoder, data: *std.ArrayList(u8), value: i64) !void {
        _ = self;
        // ZigZag encoding for signed integers
        const zigzag: u64 = @bitCast((value << 1) ^ (value >> 63));
        
        var v = zigzag;
        while (v >= 0x80) {
            try data.append(@truncate((v & 0x7F) | 0x80));
            v >>= 7;
        }
        try data.append(@truncate(v));
    }
    
    /// Decode delta-encoded data
    pub fn decode(self: *DeltaEncoder, compressed: []const u8, num_values: usize) !std.ArrayList(i64) {
        var result = std.ArrayList(i64).init(self.allocator);
        errdefer result.deinit();
        
        if (compressed.len < 8 or num_values == 0) return result;
        
        // Read first value
        var prev = std.mem.bytesToValue(i64, compressed[0..8]);
        try result.append(prev);
        
        var pos: usize = 8;
        
        while (result.items.len < num_values and pos < compressed.len) {
            const delta = try self.readVarint(compressed, &pos);
            prev = prev + delta;
            try result.append(prev);
        }
        
        return result;
    }
    
    fn readVarint(self: *DeltaEncoder, data: []const u8, pos: *usize) !i64 {
        _ = self;
        var result: u64 = 0;
        var shift: u6 = 0;
        
        while (pos.* < data.len) {
            const byte = data[pos.*];
            pos.* += 1;
            result |= @as(u64, byte & 0x7F) << shift;
            if (byte < 0x80) break;
            shift += 7;
        }
        
        // ZigZag decode
        return @bitCast((result >> 1) ^ (~(result & 1) +% 1));
    }
};

// ============================================================================
// Constant Compression (all same value)
// ============================================================================

pub const ConstantEncoder = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ConstantEncoder {
        return .{ .allocator = allocator };
    }
    
    /// Check if all values are the same
    pub fn isConstant(values: []const i64) bool {
        if (values.len <= 1) return true;
        const first = values[0];
        for (values[1..]) |v| {
            if (v != first) return false;
        }
        return true;
    }
    
    /// Encode constant values
    pub fn encode(self: *ConstantEncoder, values: []const i64) !CompressionBuffer {
        var buffer = CompressionBuffer.init(self.allocator, .CONSTANT);
        errdefer buffer.deinit();
        
        if (values.len == 0) return buffer;
        
        // Just store the value and count
        try buffer.data.appendSlice(std.mem.asBytes(&values[0]));
        const count: u64 = values.len;
        try buffer.data.appendSlice(std.mem.asBytes(&count));
        
        buffer.info.uncompressed_size = values.len * 8;
        buffer.info.compressed_size = 16;  // 8 bytes value + 8 bytes count
        buffer.info.num_values = values.len;
        
        return buffer;
    }
    
    /// Decode constant data
    pub fn decode(self: *ConstantEncoder, compressed: []const u8) !std.ArrayList(i64) {
        var result = std.ArrayList(i64).init(self.allocator);
        errdefer result.deinit();
        
        if (compressed.len < 16) return result;
        
        const value = std.mem.bytesToValue(i64, compressed[0..8]);
        const count = std.mem.bytesToValue(u64, compressed[8..16]);
        
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            try result.append(value);
        }
        
        return result;
    }
};

// ============================================================================
// Compression Selector - Auto-select best compression
// ============================================================================

pub const CompressionSelector = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) CompressionSelector {
        return .{ .allocator = allocator };
    }
    
    /// Select best compression for integer data
    pub fn selectForIntegers(self: *CompressionSelector, values: []const i64) CompressionType {
        _ = self;
        if (values.len == 0) return .UNCOMPRESSED;
        
        // Check for constant
        if (ConstantEncoder.isConstant(values)) return .CONSTANT;
        
        // Heuristics for other methods
        // TODO: Add sampling and cost estimation
        return .DELTA;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "rle encode decode" {
    const allocator = std.testing.allocator;
    
    var encoder = RLEEncoder.init(allocator);
    
    const values = [_]i64{ 1, 1, 1, 2, 2, 3, 3, 3, 3 };
    var buffer = try encoder.encode(&values);
    defer buffer.deinit();
    
    var decoded = try encoder.decode(buffer.getBytes(), values.len);
    defer decoded.deinit();
    
    try std.testing.expectEqual(values.len, decoded.items.len);
    for (values, 0..) |v, i| {
        try std.testing.expectEqual(v, decoded.items[i]);
    }
}

test "bit packing" {
    const allocator = std.testing.allocator;
    
    var encoder = BitPackingEncoder.init(allocator);
    
    const values = [_]u64{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var buffer = try encoder.encode(&values);
    defer buffer.deinit();
    
    var decoded = try encoder.decode(buffer.getBytes());
    defer decoded.deinit();
    
    try std.testing.expectEqual(values.len, decoded.items.len);
    for (values, 0..) |v, i| {
        try std.testing.expectEqual(v, decoded.items[i]);
    }
    
    // Should use 3 bits per value
    try std.testing.expect(buffer.info.compressionRatio() > 1.0);
}

test "delta encoding" {
    const allocator = std.testing.allocator;
    
    var encoder = DeltaEncoder.init(allocator);
    
    // Sequential values - great for delta
    const values = [_]i64{ 100, 101, 102, 103, 104, 105 };
    var buffer = try encoder.encode(&values);
    defer buffer.deinit();
    
    var decoded = try encoder.decode(buffer.getBytes(), values.len);
    defer decoded.deinit();
    
    try std.testing.expectEqual(values.len, decoded.items.len);
    for (values, 0..) |v, i| {
        try std.testing.expectEqual(v, decoded.items[i]);
    }
}

test "constant encoding" {
    const allocator = std.testing.allocator;
    
    var encoder = ConstantEncoder.init(allocator);
    
    const values = [_]i64{ 42, 42, 42, 42, 42 };
    try std.testing.expect(ConstantEncoder.isConstant(&values));
    
    var buffer = try encoder.encode(&values);
    defer buffer.deinit();
    
    // Should be very small
    try std.testing.expectEqual(@as(u64, 16), buffer.info.compressed_size);
    
    var decoded = try encoder.decode(buffer.getBytes());
    defer decoded.deinit();
    
    try std.testing.expectEqual(values.len, decoded.items.len);
}

test "compression info ratio" {
    const info = CompressionInfo{
        .compression_type = .RUN_LENGTH,
        .uncompressed_size = 1000,
        .compressed_size = 100,
        .num_values = 100,
    };
    
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), info.compressionRatio(), 0.001);
}