//! AIPrompt Streaming - Message Batch Decoder
//! High-performance batch message parsing for production throughput
//! 
//! Production Pulsar clients send batched payloads containing 100-1000 messages
//! per network frame to maximize throughput. This decoder efficiently parses
//! these batched payloads without excessive allocations.

const std = @import("std");

const log = std.log.scoped(.batch_decoder);

// ============================================================================
// Batch Message Format (Pulsar-compatible)
// ============================================================================

/// Batch message metadata header
pub const BatchMetadata = struct {
    /// Number of messages in the batch
    num_messages: u32,
    /// Uncompressed size of all messages
    uncompressed_size: u32,
    /// Compression codec used
    compression: CompressionCodec,
    /// Schema version hash (0 if no schema)
    schema_version: u64,
    /// Producer name hash
    producer_name_hash: u64,
    /// Sequence ID of first message in batch
    sequence_id: i64,
    /// Publish timestamp (millis since epoch)
    publish_time: i64,
    /// Optional properties count
    properties_count: u16,
};

pub const CompressionCodec = enum(u8) {
    None = 0,
    LZ4 = 1,
    ZLIB = 2,
    ZSTD = 3,
    SNAPPY = 4,
};

/// Individual message within a batch
pub const BatchedMessage = struct {
    /// Relative sequence ID within batch
    relative_sequence_id: u32,
    /// Message key (nullable)
    key: ?[]const u8,
    /// Message payload
    payload: []const u8,
    /// Event time (0 if not set)
    event_time: i64,
    /// Properties (key-value pairs)
    properties: []const Property,

    pub const Property = struct {
        key: []const u8,
        value: []const u8,
    };
};

// ============================================================================
// Batch Decoder
// ============================================================================

pub const BatchDecoder = struct {
    allocator: std.mem.Allocator,
    compression_ctx: ?*CompressionContext,
    stats: DecoderStats,

    pub const DecoderStats = struct {
        batches_decoded: std.atomic.Value(u64),
        messages_decoded: std.atomic.Value(u64),
        bytes_decompressed: std.atomic.Value(u64),
        decompression_errors: std.atomic.Value(u64),
        parse_errors: std.atomic.Value(u64),
    };

    pub fn init(allocator: std.mem.Allocator) BatchDecoder {
        return .{
            .allocator = allocator,
            .compression_ctx = null,
            .stats = .{
                .batches_decoded = std.atomic.Value(u64).init(0),
                .messages_decoded = std.atomic.Value(u64).init(0),
                .bytes_decompressed = std.atomic.Value(u64).init(0),
                .decompression_errors = std.atomic.Value(u64).init(0),
                .parse_errors = std.atomic.Value(u64).init(0),
            },
        };
    }

    pub fn deinit(self: *BatchDecoder) void {
        if (self.compression_ctx) |ctx| {
            ctx.deinit();
            self.allocator.destroy(ctx);
        }
    }

    /// Decode a batch message payload into individual messages
    pub fn decode(self: *BatchDecoder, raw_payload: []const u8) !BatchResult {
        if (raw_payload.len < @sizeOf(BatchHeader)) {
            _ = self.stats.parse_errors.fetchAdd(1, .monotonic);
            return error.PayloadTooSmall;
        }

        // Parse batch header
        const header = try self.parseBatchHeader(raw_payload);

        // Validate batch header
        if (header.magic != BATCH_MAGIC) {
            _ = self.stats.parse_errors.fetchAdd(1, .monotonic);
            return error.InvalidBatchMagic;
        }

        // Get compressed payload
        const compressed_payload = raw_payload[@sizeOf(BatchHeader)..];

        // Decompress if needed
        const decompressed = if (header.compression != .None)
            try self.decompress(compressed_payload, header.compression, header.uncompressed_size)
        else
            compressed_payload;

        defer {
            if (header.compression != .None) {
                self.allocator.free(decompressed);
            }
        }

        // Parse individual messages
        var messages = std.ArrayList(BatchedMessage).init(self.allocator);
        errdefer messages.deinit();

        var offset: usize = 0;
        var msg_idx: u32 = 0;

        while (msg_idx < header.num_messages and offset < decompressed.len) {
            const msg = try self.parseMessage(decompressed[offset..]);
            try messages.append(msg);
            offset += msg.payload.len + getMessageOverhead(msg);
            msg_idx += 1;
        }

        _ = self.stats.batches_decoded.fetchAdd(1, .monotonic);
        _ = self.stats.messages_decoded.fetchAdd(msg_idx, .monotonic);

        return BatchResult{
            .metadata = BatchMetadata{
                .num_messages = header.num_messages,
                .uncompressed_size = header.uncompressed_size,
                .compression = header.compression,
                .schema_version = header.schema_version,
                .producer_name_hash = header.producer_name_hash,
                .sequence_id = header.sequence_id,
                .publish_time = header.publish_time,
                .properties_count = header.properties_count,
            },
            .messages = try messages.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }

    /// Encode messages into a batch
    pub fn encode(self: *BatchDecoder, messages: []const BatchedMessage, compression: CompressionCodec, schema_version: u64) ![]u8 {
        // Calculate uncompressed size
        var uncompressed_size: usize = 0;
        for (messages) |msg| {
            uncompressed_size += 4 + // relative_sequence_id
                4 + (if (msg.key) |k| k.len else 0) + // key length + key
                4 + msg.payload.len + // payload length + payload
                8 + // event_time
                4 + // properties count
                getPropertiesSize(msg.properties);
        }

        // Serialize messages
        var message_buffer = try self.allocator.alloc(u8, uncompressed_size);
        defer self.allocator.free(message_buffer);

        var offset: usize = 0;
        for (messages, 0..) |msg, i| {
            // Write relative sequence ID
            std.mem.writeInt(u32, message_buffer[offset..][0..4], @intCast(i), .big);
            offset += 4;

            // Write key
            if (msg.key) |key| {
                std.mem.writeInt(u32, message_buffer[offset..][0..4], @intCast(key.len), .big);
                offset += 4;
                @memcpy(message_buffer[offset..][0..key.len], key);
                offset += key.len;
            } else {
                std.mem.writeInt(u32, message_buffer[offset..][0..4], 0, .big);
                offset += 4;
            }

            // Write payload
            std.mem.writeInt(u32, message_buffer[offset..][0..4], @intCast(msg.payload.len), .big);
            offset += 4;
            @memcpy(message_buffer[offset..][0..msg.payload.len], msg.payload);
            offset += msg.payload.len;

            // Write event time
            std.mem.writeInt(i64, message_buffer[offset..][0..8], msg.event_time, .big);
            offset += 8;

            // Write properties
            std.mem.writeInt(u32, message_buffer[offset..][0..4], @intCast(msg.properties.len), .big);
            offset += 4;
            for (msg.properties) |prop| {
                std.mem.writeInt(u16, message_buffer[offset..][0..2], @intCast(prop.key.len), .big);
                offset += 2;
                @memcpy(message_buffer[offset..][0..prop.key.len], prop.key);
                offset += prop.key.len;
                std.mem.writeInt(u32, message_buffer[offset..][0..4], @intCast(prop.value.len), .big);
                offset += 4;
                @memcpy(message_buffer[offset..][0..prop.value.len], prop.value);
                offset += prop.value.len;
            }
        }

        // Compress if needed
        const compressed_payload = if (compression != .None)
            try self.compress(message_buffer[0..offset], compression)
        else
            try self.allocator.dupe(u8, message_buffer[0..offset]);

        // Build final batch buffer
        const batch_size = @sizeOf(BatchHeader) + compressed_payload.len;
        const batch_buffer = try self.allocator.alloc(u8, batch_size);

        // Write header
        const header = BatchHeader{
            .magic = BATCH_MAGIC,
            .num_messages = @intCast(messages.len),
            .uncompressed_size = @intCast(offset),
            .compression = compression,
            .schema_version = schema_version,
            .producer_name_hash = 0,
            .sequence_id = if (messages.len > 0) messages[0].event_time else 0,
            .publish_time = std.time.milliTimestamp(),
            .properties_count = 0,
        };

        @memcpy(batch_buffer[0..@sizeOf(BatchHeader)], std.mem.asBytes(&header));
        @memcpy(batch_buffer[@sizeOf(BatchHeader)..], compressed_payload);

        if (compression != .None) {
            self.allocator.free(compressed_payload);
        }

        return batch_buffer;
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    const BATCH_MAGIC: u32 = 0x0e01;

    const BatchHeader = extern struct {
        magic: u32,
        num_messages: u32,
        uncompressed_size: u32,
        compression: CompressionCodec,
        _padding: [3]u8 = .{ 0, 0, 0 },
        schema_version: u64,
        producer_name_hash: u64,
        sequence_id: i64,
        publish_time: i64,
        properties_count: u16,
        _padding2: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    };

    fn parseBatchHeader(self: *BatchDecoder, data: []const u8) !BatchHeader {
        _ = self;
        if (data.len < @sizeOf(BatchHeader)) {
            return error.HeaderTooSmall;
        }
        return std.mem.bytesToValue(BatchHeader, data[0..@sizeOf(BatchHeader)]);
    }

    fn parseMessage(self: *BatchDecoder, data: []const u8) !BatchedMessage {
        _ = self;
        if (data.len < 20) {
            return error.MessageTooSmall;
        }

        var offset: usize = 0;

        // Read relative sequence ID
        const relative_seq = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        // Read key
        const key_len = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        const key: ?[]const u8 = if (key_len > 0) data[offset..][0..key_len] else null;
        offset += key_len;

        // Read payload
        const payload_len = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        const payload = data[offset..][0..payload_len];
        offset += payload_len;

        // Read event time
        const event_time = std.mem.readInt(i64, data[offset..][0..8], .big);
        offset += 8;

        // Read properties count (skip for now)
        _ = std.mem.readInt(u32, data[offset..][0..4], .big);

        return BatchedMessage{
            .relative_sequence_id = relative_seq,
            .key = key,
            .payload = payload,
            .event_time = event_time,
            .properties = &[_]BatchedMessage.Property{},
        };
    }

    fn getMessageOverhead(msg: BatchedMessage) usize {
        return 4 + 4 + (if (msg.key) |k| k.len else 0) + 4 + 8 + 4;
    }

    fn getPropertiesSize(properties: []const BatchedMessage.Property) usize {
        var size: usize = 0;
        for (properties) |prop| {
            size += 2 + prop.key.len + 4 + prop.value.len;
        }
        return size;
    }

    fn decompress(self: *BatchDecoder, data: []const u8, codec: CompressionCodec, expected_size: u32) ![]u8 {
        _ = self.stats.bytes_decompressed.fetchAdd(data.len, .monotonic);

        return switch (codec) {
            .LZ4 => try decompressLz4(self.allocator, data, expected_size),
            .ZSTD => try decompressZstd(self.allocator, data, expected_size),
            .ZLIB => try decompressZlib(self.allocator, data, expected_size),
            .SNAPPY => error.UnsupportedCodec,
            .None => error.InvalidCompression,
        };
    }

    fn compress(self: *BatchDecoder, data: []const u8, codec: CompressionCodec) ![]u8 {
        return switch (codec) {
            .LZ4 => try compressLz4(self.allocator, data),
            .ZSTD => try compressZstd(self.allocator, data),
            .ZLIB => try compressZlib(self.allocator, data),
            .SNAPPY => error.UnsupportedCodec,
            .None => error.InvalidCompression,
        };
    }
};

pub const BatchResult = struct {
    metadata: BatchMetadata,
    messages: []BatchedMessage,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BatchResult) void {
        self.allocator.free(self.messages);
    }
};

// ============================================================================
// Compression Context (for reusing buffers)
// ============================================================================

pub const CompressionContext = struct {
    allocator: std.mem.Allocator,
    lz4_buffer: ?[]u8,
    zstd_buffer: ?[]u8,

    pub fn init(allocator: std.mem.Allocator) CompressionContext {
        return .{
            .allocator = allocator,
            .lz4_buffer = null,
            .zstd_buffer = null,
        };
    }

    pub fn deinit(self: *CompressionContext) void {
        if (self.lz4_buffer) |buf| {
            self.allocator.free(buf);
        }
        if (self.zstd_buffer) |buf| {
            self.allocator.free(buf);
        }
    }
};

// ============================================================================
// LZ4 Compression (via C library)
// ============================================================================

// LZ4 C-ABI bindings
extern "c" fn LZ4_decompress_safe(src: [*]const u8, dst: [*]u8, compressedSize: c_int, dstCapacity: c_int) c_int;
extern "c" fn LZ4_compress_default(src: [*]const u8, dst: [*]u8, srcSize: c_int, dstCapacity: c_int) c_int;
extern "c" fn LZ4_compressBound(inputSize: c_int) c_int;

fn decompressLz4(allocator: std.mem.Allocator, compressed: []const u8, expected_size: u32) ![]u8 {
    const output = try allocator.alloc(u8, expected_size);
    errdefer allocator.free(output);

    const result = LZ4_decompress_safe(
        compressed.ptr,
        output.ptr,
        @intCast(compressed.len),
        @intCast(expected_size),
    );

    if (result < 0) {
        return error.Lz4DecompressionFailed;
    }

    return output[0..@intCast(result)];
}

fn compressLz4(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const bound = LZ4_compressBound(@intCast(data.len));
    const output = try allocator.alloc(u8, @intCast(bound));
    errdefer allocator.free(output);

    const result = LZ4_compress_default(
        data.ptr,
        output.ptr,
        @intCast(data.len),
        bound,
    );

    if (result <= 0) {
        return error.Lz4CompressionFailed;
    }

    return try allocator.realloc(output, @intCast(result));
}

// ============================================================================
// ZSTD Compression (via C library)
// ============================================================================

// ZSTD C-ABI bindings
extern "c" fn ZSTD_decompress(dst: [*]u8, dstCapacity: usize, src: [*]const u8, compressedSize: usize) usize;
extern "c" fn ZSTD_compress(dst: [*]u8, dstCapacity: usize, src: [*]const u8, srcSize: usize, compressionLevel: c_int) usize;
extern "c" fn ZSTD_compressBound(srcSize: usize) usize;
extern "c" fn ZSTD_isError(code: usize) c_uint;

fn decompressZstd(allocator: std.mem.Allocator, compressed: []const u8, expected_size: u32) ![]u8 {
    const output = try allocator.alloc(u8, expected_size);
    errdefer allocator.free(output);

    const result = ZSTD_decompress(
        output.ptr,
        expected_size,
        compressed.ptr,
        compressed.len,
    );

    if (ZSTD_isError(result) != 0) {
        return error.ZstdDecompressionFailed;
    }

    return output[0..result];
}

fn compressZstd(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const bound = ZSTD_compressBound(data.len);
    const output = try allocator.alloc(u8, bound);
    errdefer allocator.free(output);

    const result = ZSTD_compress(
        output.ptr,
        bound,
        data.ptr,
        data.len,
        3, // Default compression level
    );

    if (ZSTD_isError(result) != 0) {
        return error.ZstdCompressionFailed;
    }

    return try allocator.realloc(output, result);
}

// ============================================================================
// ZLIB Compression (via Zig std)
// ============================================================================

fn decompressZlib(allocator: std.mem.Allocator, compressed: []const u8, expected_size: u32) ![]u8 {
    var output = try allocator.alloc(u8, expected_size);
    errdefer allocator.free(output);

    var stream = std.compress.zlib.decompressor(std.io.fixedBufferStream(compressed).reader());
    const bytes_read = try stream.reader().readAll(output);

    if (bytes_read < expected_size) {
        output = try allocator.realloc(output, bytes_read);
    }

    return output;
}

fn compressZlib(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    var compressor = try std.compress.zlib.compressor(output.writer(), .{});
    try compressor.writer().writeAll(data);
    try compressor.finish();

    return try output.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "BatchDecoder init/deinit" {
    const allocator = std.testing.allocator;
    var decoder = BatchDecoder.init(allocator);
    defer decoder.deinit();

    try std.testing.expectEqual(@as(u64, 0), decoder.stats.batches_decoded.load(.monotonic));
}

test "CompressionCodec values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(CompressionCodec.None));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(CompressionCodec.LZ4));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(CompressionCodec.ZSTD));
}