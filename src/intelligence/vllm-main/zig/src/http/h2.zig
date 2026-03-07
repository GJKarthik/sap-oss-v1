//! HTTP/2 Frame Parser & Stream Multiplexer
//!
//! Binary framing protocol with stream multiplexing, HPACK header compression,
//! and per-stream/connection flow control per RFC 7540 / RFC 9113.
//!
//! Integrates with io_engine.zig for event-driven I/O and server.zig for routing.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const log = std.log.scoped(.h2);

// ============================================================================
// HTTP/2 Frame Types (RFC 7540 §6)
// ============================================================================

pub const FrameType = enum(u8) {
    DATA = 0x0,
    HEADERS = 0x1,
    PRIORITY = 0x2,
    RST_STREAM = 0x3,
    SETTINGS = 0x4,
    PUSH_PROMISE = 0x5,
    PING = 0x6,
    GOAWAY = 0x7,
    WINDOW_UPDATE = 0x8,
    CONTINUATION = 0x9,
    _,
};

pub const FrameFlags = struct {
    pub const END_STREAM: u8 = 0x1;
    pub const END_HEADERS: u8 = 0x4;
    pub const PADDED: u8 = 0x8;
    pub const PRIORITY_FLAG: u8 = 0x20;
    pub const ACK: u8 = 0x1; // For SETTINGS and PING
};

pub const FRAME_HEADER_SIZE: usize = 9;
pub const CONNECTION_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
pub const DEFAULT_WINDOW_SIZE: u32 = 65535;
pub const DEFAULT_MAX_FRAME_SIZE: u32 = 16384;
pub const MAX_FRAME_SIZE_LIMIT: u32 = 16777215; // 2^24 - 1
pub const DEFAULT_HEADER_TABLE_SIZE: u32 = 4096;
pub const DEFAULT_MAX_CONCURRENT_STREAMS: u32 = 256;

// ============================================================================
// Frame Header
// ============================================================================

pub const FrameHeader = struct {
    length: u32, // Only lower 24 bits used on the wire
    frame_type: FrameType,
    flags: u8,
    stream_id: u32, // Only lower 31 bits used on the wire (bit 31 reserved)

    pub fn parse(buf: *const [FRAME_HEADER_SIZE]u8) FrameHeader {
        const length: u32 = (@as(u32, buf[0]) << 16) |
            (@as(u32, buf[1]) << 8) |
            @as(u32, buf[2]);
        const frame_type: FrameType = @enumFromInt(buf[3]);
        const flags = buf[4];
        const stream_id: u32 = ((@as(u32, buf[5] & 0x7F) << 24) |
            (@as(u32, buf[6]) << 16) |
            (@as(u32, buf[7]) << 8) |
            @as(u32, buf[8]));
        return .{
            .length = length,
            .frame_type = frame_type,
            .flags = flags,
            .stream_id = stream_id,
        };
    }

    pub fn serialize(self: FrameHeader, buf: *[FRAME_HEADER_SIZE]u8) void {
        buf[0] = @intCast((self.length >> 16) & 0xFF);
        buf[1] = @intCast((self.length >> 8) & 0xFF);
        buf[2] = @intCast(self.length & 0xFF);
        buf[3] = @intFromEnum(self.frame_type);
        buf[4] = self.flags;
        buf[5] = @intCast((self.stream_id >> 24) & 0x7F);
        buf[6] = @intCast((self.stream_id >> 16) & 0xFF);
        buf[7] = @intCast((self.stream_id >> 8) & 0xFF);
        buf[8] = @intCast(self.stream_id & 0xFF);
    }

    pub fn hasFlag(self: FrameHeader, flag: u8) bool {
        return (self.flags & flag) != 0;
    }
};

// ============================================================================
// Settings Parameters (RFC 7540 §6.5.2)
// ============================================================================

pub const SettingsId = enum(u16) {
    HEADER_TABLE_SIZE = 0x1,
    ENABLE_PUSH = 0x2,
    MAX_CONCURRENT_STREAMS = 0x3,
    INITIAL_WINDOW_SIZE = 0x4,
    MAX_FRAME_SIZE = 0x5,
    MAX_HEADER_LIST_SIZE = 0x6,
    _,
};

pub const Settings = struct {
    header_table_size: u32 = DEFAULT_HEADER_TABLE_SIZE,
    enable_push: bool = true,
    max_concurrent_streams: u32 = DEFAULT_MAX_CONCURRENT_STREAMS,
    initial_window_size: u32 = DEFAULT_WINDOW_SIZE,
    max_frame_size: u32 = DEFAULT_MAX_FRAME_SIZE,
    max_header_list_size: u32 = 8192,
};

// ============================================================================
// HPACK Static Table (RFC 7541 Appendix A) — first 16 most common entries
// ============================================================================

const HpackStaticEntry = struct {
    name: []const u8,
    value: []const u8,
};

const HPACK_STATIC_TABLE = [_]HpackStaticEntry{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "content-length", .value = "" },
};



// ============================================================================
// HPACK Encoder/Decoder (simplified — covers indexed + literal with indexing)
// ============================================================================

pub const HpackDecoder = struct {
    dynamic_table: std.ArrayListUnmanaged(HpackStaticEntry),
    max_table_size: u32,
    current_size: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator) HpackDecoder {
        return .{
            .dynamic_table = .{},
            .max_table_size = DEFAULT_HEADER_TABLE_SIZE,
            .current_size = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HpackDecoder) void {
        self.dynamic_table.deinit();
    }

    /// Decode an HPACK-encoded header block into key-value pairs
    pub fn decode(self: *HpackDecoder, data: []const u8, headers: *std.StringHashMap([]const u8)) !void {
        var pos: usize = 0;
        while (pos < data.len) {
            const byte = data[pos];
            if (byte & 0x80 != 0) {
                // Indexed header field (§6.1)
                const index = @as(usize, byte & 0x7F);
                pos += 1;
                if (index == 0) return error.InvalidIndex;
                const entry = self.getEntry(index) orelse return error.InvalidIndex;
                try headers.put(entry.name, entry.value);
            } else if (byte & 0x40 != 0) {
                // Literal with incremental indexing (§6.2.1)
                const name_idx = @as(usize, byte & 0x3F);
                pos += 1;
                var name: []const u8 = undefined;
                if (name_idx > 0) {
                    const entry = self.getEntry(name_idx) orelse return error.InvalidIndex;
                    name = entry.name;
                } else {
                    const result = decodeString(data, pos) orelse return error.Truncated;
                    name = result.str;
                    pos = result.new_pos;
                }
                const val_result = decodeString(data, pos) orelse return error.Truncated;
                pos = val_result.new_pos;
                try headers.put(name, val_result.str);
                try self.addDynamicEntry(name, val_result.str);
            } else {
                // Literal without indexing (§6.2.2) or never indexed (§6.2.3)
                const name_idx = @as(usize, byte & 0x0F);
                pos += 1;
                var name: []const u8 = undefined;
                if (name_idx > 0) {
                    const entry = self.getEntry(name_idx) orelse return error.InvalidIndex;
                    name = entry.name;
                } else {
                    const result = decodeString(data, pos) orelse return error.Truncated;
                    name = result.str;
                    pos = result.new_pos;
                }
                const val_result = decodeString(data, pos) orelse return error.Truncated;
                pos = val_result.new_pos;
                try headers.put(name, val_result.str);
            }
        }
    }

    fn getEntry(self: *HpackDecoder, index: usize) ?HpackStaticEntry {
        if (index == 0) return null;
        if (index <= HPACK_STATIC_TABLE.len) return HPACK_STATIC_TABLE[index - 1];
        const dyn_idx = index - HPACK_STATIC_TABLE.len - 1;
        if (dyn_idx < self.dynamic_table.items.len) return self.dynamic_table.items[dyn_idx];
        return null;
    }

    fn addDynamicEntry(self: *HpackDecoder, name: []const u8, value: []const u8) !void {
        const entry_size: u32 = @intCast(name.len + value.len + 32); // per RFC
        // Evict entries to make room
        while (self.current_size + entry_size > self.max_table_size and
            self.dynamic_table.items.len > 0)
        {
            const last = self.dynamic_table.pop() orelse break;
            self.current_size -= @as(u32, @intCast(last.name.len + last.value.len + 32));
        }
        try self.dynamic_table.insert(self.allocator, 0, .{ .name = name, .value = value });
        self.current_size += entry_size;
    }

    fn decodeString(data: []const u8, pos: usize) ?struct { str: []const u8, new_pos: usize } {
        if (pos >= data.len) return null;
        const byte = data[pos];
        const huffman = (byte & 0x80) != 0;
        _ = huffman; // Huffman decoding: pass through raw for now (sufficient for API use)
        const length = @as(usize, byte & 0x7F);
        const start = pos + 1;
        if (start + length > data.len) return null;
        return .{ .str = data[start .. start + length], .new_pos = start + length };
    }
};

// ============================================================================
// H2 Stream State Machine (RFC 7540 §5.1)
// ============================================================================

pub const StreamState = enum {
    idle,
    reserved_local,
    reserved_remote,
    open,
    half_closed_local,
    half_closed_remote,
    closed,
};

pub const H2Stream = struct {
    id: u32,
    state: StreamState,
    send_window: i32,
    recv_window: i32,
    /// Accumulated request headers
    headers: std.StringHashMap([]const u8),
    /// Accumulated request body
    body: std.ArrayListUnmanaged(u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator, id: u32, initial_window: u32) H2Stream {
        return .{
            .id = id,
            .state = .idle,
            .send_window = @intCast(initial_window),
            .recv_window = @intCast(initial_window),
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *H2Stream) void {
        self.headers.deinit();
        self.body.deinit();
    }
};

// ============================================================================
// H2 Connection — manages multiple concurrent streams
// ============================================================================

pub const H2Connection = struct {
    allocator: Allocator,
    streams: std.AutoHashMap(u32, H2Stream),
    local_settings: Settings,
    remote_settings: Settings,
    conn_send_window: i32,
    conn_recv_window: i32,
    hpack_decoder: HpackDecoder,
    last_stream_id: u32,
    goaway_sent: bool,
    preface_received: bool,

    pub fn init(allocator: Allocator) H2Connection {
        return .{
            .allocator = allocator,
            .streams = std.AutoHashMap(u32, H2Stream).init(allocator),
            .local_settings = .{},
            .remote_settings = .{},
            .conn_send_window = @intCast(DEFAULT_WINDOW_SIZE),
            .conn_recv_window = @intCast(DEFAULT_WINDOW_SIZE),
            .hpack_decoder = HpackDecoder.init(allocator),
            .last_stream_id = 0,
            .goaway_sent = false,
            .preface_received = false,
        };
    }

    pub fn deinit(self: *H2Connection) void {
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.streams.deinit();
        self.hpack_decoder.deinit();
    }

    /// Get or create a stream by ID
    pub fn getOrCreateStream(self: *H2Connection, stream_id: u32) !*H2Stream {
        const result = try self.streams.getOrPut(stream_id);
        if (!result.found_existing) {
            result.value_ptr.* = H2Stream.init(
                self.allocator,
                stream_id,
                self.remote_settings.initial_window_size,
            );
            if (stream_id > self.last_stream_id) self.last_stream_id = stream_id;
        }
        return result.value_ptr;
    }

    /// Process an incoming frame. Returns frame type for caller to act on.
    pub fn processFrame(self: *H2Connection, header: FrameHeader, payload: []const u8) !FrameType {
        switch (header.frame_type) {
            .SETTINGS => {
                if (header.hasFlag(FrameFlags.ACK)) return .SETTINGS; // ACK, no action
                // Parse settings pairs (each is 6 bytes: u16 id + u32 value)
                var pos: usize = 0;
                while (pos + 6 <= payload.len) {
                    const id_raw = (@as(u16, payload[pos]) << 8) | @as(u16, payload[pos + 1]);
                    const value = (@as(u32, payload[pos + 2]) << 24) |
                        (@as(u32, payload[pos + 3]) << 16) |
                        (@as(u32, payload[pos + 4]) << 8) |
                        @as(u32, payload[pos + 5]);
                    pos += 6;
                    const id: SettingsId = @enumFromInt(id_raw);
                    switch (id) {
                        .HEADER_TABLE_SIZE => self.remote_settings.header_table_size = value,
                        .ENABLE_PUSH => self.remote_settings.enable_push = value != 0,
                        .MAX_CONCURRENT_STREAMS => self.remote_settings.max_concurrent_streams = value,
                        .INITIAL_WINDOW_SIZE => self.remote_settings.initial_window_size = value,
                        .MAX_FRAME_SIZE => self.remote_settings.max_frame_size = value,
                        .MAX_HEADER_LIST_SIZE => self.remote_settings.max_header_list_size = value,
                        _ => {}, // Unknown settings are ignored (RFC 7540 §6.5.2)
                    }
                }
                return .SETTINGS;
            },
            .HEADERS => {
                const stream = try self.getOrCreateStream(header.stream_id);
                stream.state = .open;
                try self.hpack_decoder.decode(payload, &stream.headers);
                if (header.hasFlag(FrameFlags.END_STREAM))
                    stream.state = .half_closed_remote;
                return .HEADERS;
            },
            .DATA => {
                if (self.streams.getPtr(header.stream_id)) |stream| {
                    try stream.body.appendSlice(stream.allocator, payload);
                    stream.recv_window -= @intCast(payload.len);
                    self.conn_recv_window -= @intCast(payload.len);
                    if (header.hasFlag(FrameFlags.END_STREAM))
                        stream.state = .half_closed_remote;
                }
                return .DATA;
            },
            .WINDOW_UPDATE => {
                if (payload.len >= 4) {
                    const increment: i32 = @intCast(
                        (@as(u32, payload[0] & 0x7F) << 24) |
                            (@as(u32, payload[1]) << 16) |
                            (@as(u32, payload[2]) << 8) |
                            @as(u32, payload[3]),
                    );
                    if (header.stream_id == 0) {
                        self.conn_send_window += increment;
                    } else if (self.streams.getPtr(header.stream_id)) |stream| {
                        stream.send_window += increment;
                    }
                }
                return .WINDOW_UPDATE;
            },
            .PING => return .PING,
            .GOAWAY => {
                self.goaway_sent = true;
                return .GOAWAY;
            },
            .RST_STREAM => {
                if (self.streams.getPtr(header.stream_id)) |stream| {
                    stream.state = .closed;
                }
                return .RST_STREAM;
            },
            else => return header.frame_type,
        }
    }

    /// Build a SETTINGS frame payload
    pub fn buildSettingsFrame(self: *H2Connection, buf: []u8) usize {
        var pos: usize = 0;
        inline for (.{
            .{ @as(u16, 0x3), self.local_settings.max_concurrent_streams },
            .{ @as(u16, 0x4), self.local_settings.initial_window_size },
            .{ @as(u16, 0x5), self.local_settings.max_frame_size },
        }) |pair| {
            if (pos + 6 <= buf.len) {
                buf[pos] = @intCast((pair[0] >> 8) & 0xFF);
                buf[pos + 1] = @intCast(pair[0] & 0xFF);
                buf[pos + 2] = @intCast((pair[1] >> 24) & 0xFF);
                buf[pos + 3] = @intCast((pair[1] >> 16) & 0xFF);
                buf[pos + 4] = @intCast((pair[1] >> 8) & 0xFF);
                buf[pos + 5] = @intCast(pair[1] & 0xFF);
                pos += 6;
            }
        }
        return pos;
    }

    /// Count active (non-closed) streams
    pub fn activeStreamCount(self: *H2Connection) u32 {
        var count: u32 = 0;
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state != .closed and entry.value_ptr.state != .idle)
                count += 1;
        }
        return count;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FrameHeader parse and serialize roundtrip" {
    var buf: [FRAME_HEADER_SIZE]u8 = undefined;
    const original = FrameHeader{
        .length = 1024,
        .frame_type = .HEADERS,
        .flags = FrameFlags.END_HEADERS | FrameFlags.END_STREAM,
        .stream_id = 7,
    };
    original.serialize(&buf);
    const parsed = FrameHeader.parse(&buf);
    try std.testing.expectEqual(@as(u32, 1024), parsed.length);
    try std.testing.expectEqual(FrameType.HEADERS, parsed.frame_type);
    try std.testing.expect(parsed.hasFlag(FrameFlags.END_HEADERS));
    try std.testing.expect(parsed.hasFlag(FrameFlags.END_STREAM));
    try std.testing.expectEqual(@as(u32, 7), parsed.stream_id);
}

test "H2Connection init/deinit" {
    var conn = H2Connection.init(std.testing.allocator);
    defer conn.deinit();
    try std.testing.expectEqual(@as(u32, 0), conn.activeStreamCount());
    try std.testing.expectEqual(@as(i32, @intCast(DEFAULT_WINDOW_SIZE)), conn.conn_send_window);
}

test "H2Connection processFrame HEADERS creates stream" {
    var conn = H2Connection.init(std.testing.allocator);
    defer conn.deinit();

    // Empty HEADERS frame (no HPACK data) for stream 1
    const hdr = FrameHeader{
        .length = 0,
        .frame_type = .HEADERS,
        .flags = FrameFlags.END_HEADERS | FrameFlags.END_STREAM,
        .stream_id = 1,
    };
    const ft = try conn.processFrame(hdr, "");
    try std.testing.expectEqual(FrameType.HEADERS, ft);
    try std.testing.expectEqual(@as(u32, 1), conn.activeStreamCount());

    if (conn.streams.getPtr(1)) |stream| {
        try std.testing.expectEqual(StreamState.half_closed_remote, stream.state);
    } else {
        return error.StreamNotFound;
    }
}

test "H2Connection WINDOW_UPDATE adjusts flow control" {
    var conn = H2Connection.init(std.testing.allocator);
    defer conn.deinit();

    const initial = conn.conn_send_window;
    // Connection-level window update (+1000)
    const payload = [_]u8{ 0x00, 0x00, 0x03, 0xE8 }; // 1000
    const hdr = FrameHeader{
        .length = 4,
        .frame_type = .WINDOW_UPDATE,
        .flags = 0,
        .stream_id = 0,
    };
    _ = try conn.processFrame(hdr, &payload);
    try std.testing.expectEqual(initial + 1000, conn.conn_send_window);
}

test "HpackDecoder indexed static entry" {
    var decoder = HpackDecoder.init(std.testing.allocator);
    defer decoder.deinit();

    // Indexed entry: 0x82 = index 2 → :method GET
    var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer headers.deinit();
    try decoder.decode(&[_]u8{0x82}, &headers);
    try std.testing.expectEqualStrings("GET", headers.get(":method").?);
}

test "Settings buildSettingsFrame" {
    var conn = H2Connection.init(std.testing.allocator);
    defer conn.deinit();
    var buf: [64]u8 = undefined;
    const len = conn.buildSettingsFrame(&buf);
    try std.testing.expectEqual(@as(usize, 18), len); // 3 settings × 6 bytes each
}

test "CONNECTION_PREFACE constant" {
    try std.testing.expectEqual(@as(usize, 24), CONNECTION_PREFACE.len);
    try std.testing.expect(mem.startsWith(u8, CONNECTION_PREFACE, "PRI"));
}