//! AIPrompt Streaming - Write-Ahead Log (WAL)
//! Durable transaction logging for crash recovery
//!
//! The WAL ensures that all state changes are persisted before being applied,
//! enabling the broker to recover its exact state after a crash. This is critical
//! for production systems handling 100K+ messages per second.

const std = @import("std");

const log = std.log.scoped(.wal);

// ============================================================================
// WAL Record Types
// ============================================================================

pub const RecordType = enum(u8) {
    /// Transaction begin marker
    BeginTxn = 0x01,
    /// Transaction commit marker
    CommitTxn = 0x02,
    /// Transaction rollback marker
    RollbackTxn = 0x03,
    /// Topic created
    TopicCreated = 0x10,
    /// Topic deleted
    TopicDeleted = 0x11,
    /// Topic configuration changed
    TopicConfigChanged = 0x12,
    /// Subscription created
    SubscriptionCreated = 0x20,
    /// Subscription deleted
    SubscriptionDeleted = 0x21,
    /// Cursor position updated
    CursorUpdated = 0x22,
    /// Message published
    MessagePublished = 0x30,
    /// Message acknowledged
    MessageAcked = 0x31,
    /// Batch acknowledged
    BatchAcked = 0x32,
    /// Ledger created
    LedgerCreated = 0x40,
    /// Ledger closed
    LedgerClosed = 0x41,
    /// Ledger trimmed
    LedgerTrimmed = 0x42,
    /// Checkpoint marker
    Checkpoint = 0x50,
    /// Schema registered
    SchemaRegistered = 0x60,
    /// Broker state snapshot
    BrokerSnapshot = 0x70,
};

pub const WALRecord = struct {
    /// Log sequence number (monotonically increasing)
    lsn: u64,
    /// Record type
    record_type: RecordType,
    /// Transaction ID (0 for non-transactional)
    txn_id: u64,
    /// Timestamp (nanos since epoch)
    timestamp: i64,
    /// CRC32 checksum of payload
    checksum: u32,
    /// Payload length
    payload_len: u32,
    /// Variable-length payload
    payload: []const u8,

    pub const HEADER_SIZE = 8 + 1 + 8 + 8 + 4 + 4; // 33 bytes

    pub fn serialize(self: *const WALRecord, buffer: []u8) !usize {
        if (buffer.len < HEADER_SIZE + self.payload_len) {
            return error.BufferTooSmall;
        }

        var offset: usize = 0;

        // LSN (8 bytes)
        std.mem.writeInt(u64, buffer[offset..][0..8], self.lsn, .little);
        offset += 8;

        // Record type (1 byte)
        buffer[offset] = @intFromEnum(self.record_type);
        offset += 1;

        // Transaction ID (8 bytes)
        std.mem.writeInt(u64, buffer[offset..][0..8], self.txn_id, .little);
        offset += 8;

        // Timestamp (8 bytes)
        std.mem.writeInt(i64, buffer[offset..][0..8], self.timestamp, .little);
        offset += 8;

        // Checksum (4 bytes)
        std.mem.writeInt(u32, buffer[offset..][0..4], self.checksum, .little);
        offset += 4;

        // Payload length (4 bytes)
        std.mem.writeInt(u32, buffer[offset..][0..4], self.payload_len, .little);
        offset += 4;

        // Payload
        @memcpy(buffer[offset..][0..self.payload_len], self.payload);
        offset += self.payload_len;

        return offset;
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !WALRecord {
        if (data.len < HEADER_SIZE) {
            return error.DataTooSmall;
        }

        var offset: usize = 0;

        const lsn = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;

        const record_type: RecordType = @enumFromInt(data[offset]);
        offset += 1;

        const txn_id = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;

        const timestamp = std.mem.readInt(i64, data[offset..][0..8], .little);
        offset += 8;

        const checksum = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        const payload_len = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        if (data.len < HEADER_SIZE + payload_len) {
            return error.IncompleteRecord;
        }

        const payload = try allocator.dupe(u8, data[offset..][0..payload_len]);

        return WALRecord{
            .lsn = lsn,
            .record_type = record_type,
            .txn_id = txn_id,
            .timestamp = timestamp,
            .checksum = checksum,
            .payload_len = payload_len,
            .payload = payload,
        };
    }
};

// ============================================================================
// WAL Segment (Individual log file)
// ============================================================================

pub const WALSegment = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    file: ?std.fs.File,
    segment_id: u64,
    start_lsn: u64,
    end_lsn: u64,
    size: usize,
    max_size: usize,
    is_sealed: bool,

    pub const SEGMENT_MAGIC: u32 = 0x57414C53; // "WALS"
    pub const HEADER_SIZE = 24; // magic(4) + version(4) + segment_id(8) + start_lsn(8)

    pub fn create(allocator: std.mem.Allocator, dir: []const u8, segment_id: u64, start_lsn: u64, max_size: usize) !WALSegment {
        const path = try std.fmt.allocPrint(allocator, "{s}/wal_{:0>16x}.log", .{ dir, segment_id });

        const file = try std.fs.cwd().createFile(path, .{ .read = true });

        // Write segment header
        var header: [HEADER_SIZE]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], SEGMENT_MAGIC, .little);
        std.mem.writeInt(u32, header[4..8], 1, .little); // version
        std.mem.writeInt(u64, header[8..16], segment_id, .little);
        std.mem.writeInt(u64, header[16..24], start_lsn, .little);

        try file.writeAll(&header);

        return WALSegment{
            .allocator = allocator,
            .path = path,
            .file = file,
            .segment_id = segment_id,
            .start_lsn = start_lsn,
            .end_lsn = start_lsn,
            .size = HEADER_SIZE,
            .max_size = max_size,
            .is_sealed = false,
        };
    }

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !WALSegment {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });

        // Read and validate header
        var header: [HEADER_SIZE]u8 = undefined;
        _ = try file.readAll(&header);

        const magic = std.mem.readInt(u32, header[0..4], .little);
        if (magic != SEGMENT_MAGIC) {
            return error.InvalidSegmentMagic;
        }

        const segment_id = std.mem.readInt(u64, header[8..16], .little);
        const start_lsn = std.mem.readInt(u64, header[16..24], .little);

        const stat = try file.stat();

        return WALSegment{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .file = file,
            .segment_id = segment_id,
            .start_lsn = start_lsn,
            .end_lsn = start_lsn, // Will be updated during recovery
            .size = stat.size,
            .max_size = 256 * 1024 * 1024, // 256 MB default
            .is_sealed = true, // Existing segments are sealed
        };
    }

    pub fn deinit(self: *WALSegment) void {
        if (self.file) |f| {
            f.close();
        }
        self.allocator.free(self.path);
    }

    pub fn append(self: *WALSegment, record: *const WALRecord) !void {
        if (self.is_sealed) {
            return error.SegmentSealed;
        }

        const record_size = WALRecord.HEADER_SIZE + record.payload_len;
        if (self.size + record_size > self.max_size) {
            return error.SegmentFull;
        }

        var buffer: [65536]u8 = undefined;
        const written = try record.serialize(&buffer);

        if (self.file) |f| {
            try f.seekTo(self.size);
            try f.writeAll(buffer[0..written]);
            try f.sync();
        }

        self.size += written;
        self.end_lsn = record.lsn;
    }

    pub fn seal(self: *WALSegment) !void {
        if (self.file) |f| {
            try f.sync();
        }
        self.is_sealed = true;
    }

    pub fn hasSpace(self: *const WALSegment, record_size: usize) bool {
        return self.size + record_size <= self.max_size;
    }
};

// ============================================================================
// Write-Ahead Log Manager
// ============================================================================

pub const WAL = struct {
    allocator: std.mem.Allocator,
    config: WALConfig,
    dir: []const u8,

    // Current state
    current_lsn: std.atomic.Value(u64),
    current_txn_id: std.atomic.Value(u64),
    current_segment: ?*WALSegment,
    segments: std.ArrayList(*WALSegment),

    // Synchronization
    mutex: std.Thread.Mutex,
    sync_requested: std.atomic.Value(bool),

    // Statistics
    records_written: std.atomic.Value(u64),
    bytes_written: std.atomic.Value(u64),
    syncs_performed: std.atomic.Value(u64),
    checkpoints_created: std.atomic.Value(u64),

    pub const WALConfig = struct {
        segment_size: usize = 256 * 1024 * 1024, // 256 MB
        sync_interval_ms: u64 = 100,
        max_segments: usize = 100,
        checkpoint_interval_lsns: u64 = 100_000,
        compression_enabled: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, dir: []const u8, config: WALConfig) !WAL {
        // Create WAL directory if it doesn't exist
        std.fs.cwd().makeDir(dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                return err;
            }
        };

        return WAL{
            .allocator = allocator,
            .config = config,
            .dir = try allocator.dupe(u8, dir),
            .current_lsn = std.atomic.Value(u64).init(0),
            .current_txn_id = std.atomic.Value(u64).init(0),
            .current_segment = null,
            .segments = std.ArrayList(*WALSegment).init(allocator),
            .mutex = .{},
            .sync_requested = std.atomic.Value(bool).init(false),
            .records_written = std.atomic.Value(u64).init(0),
            .bytes_written = std.atomic.Value(u64).init(0),
            .syncs_performed = std.atomic.Value(u64).init(0),
            .checkpoints_created = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *WAL) void {
        if (self.current_segment) |seg| {
            seg.deinit();
            self.allocator.destroy(seg);
        }

        for (self.segments.items) |seg| {
            seg.deinit();
            self.allocator.destroy(seg);
        }
        self.segments.deinit();

        self.allocator.free(self.dir);
    }

    /// Begin a new transaction
    pub fn beginTransaction(self: *WAL) !u64 {
        const txn_id = self.current_txn_id.fetchAdd(1, .monotonic) + 1;

        try self.appendRecord(.BeginTxn, txn_id, &[_]u8{});

        return txn_id;
    }

    /// Commit a transaction
    pub fn commitTransaction(self: *WAL, txn_id: u64) !void {
        try self.appendRecord(.CommitTxn, txn_id, &[_]u8{});
    }

    /// Rollback a transaction
    pub fn rollbackTransaction(self: *WAL, txn_id: u64) !void {
        try self.appendRecord(.RollbackTxn, txn_id, &[_]u8{});
    }

    /// Append a record to the WAL
    pub fn appendRecord(self: *WAL, record_type: RecordType, txn_id: u64, payload: []const u8) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Get next LSN
        const lsn = self.current_lsn.fetchAdd(1, .monotonic) + 1;

        // Compute checksum
        const checksum = computeCrc32(payload);

        const record = WALRecord{
            .lsn = lsn,
            .record_type = record_type,
            .txn_id = txn_id,
            .timestamp = std.time.nanoTimestamp(),
            .checksum = checksum,
            .payload_len = @intCast(payload.len),
            .payload = payload,
        };

        // Ensure we have an active segment
        try self.ensureActiveSegment(WALRecord.HEADER_SIZE + payload.len);

        // Write to current segment
        try self.current_segment.?.append(&record);

        // Update stats
        _ = self.records_written.fetchAdd(1, .monotonic);
        _ = self.bytes_written.fetchAdd(WALRecord.HEADER_SIZE + payload.len, .monotonic);

        return lsn;
    }

    /// Create a checkpoint
    pub fn createCheckpoint(self: *WAL, state_data: []const u8) !u64 {
        const lsn = try self.appendRecord(.Checkpoint, 0, state_data);
        _ = self.checkpoints_created.fetchAdd(1, .monotonic);
        log.info("Created checkpoint at LSN {}", .{lsn});
        return lsn;
    }

    /// Sync WAL to disk
    pub fn sync(self: *WAL) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.current_segment) |seg| {
            if (seg.file) |f| {
                try f.sync();
            }
        }
        _ = self.syncs_performed.fetchAdd(1, .monotonic);
    }

    /// Get current LSN
    pub fn getCurrentLsn(self: *WAL) u64 {
        return self.current_lsn.load(.monotonic);
    }

    /// Get WAL statistics
    pub fn getStats(self: *WAL) WALStats {
        return .{
            .current_lsn = self.current_lsn.load(.monotonic),
            .current_txn_id = self.current_txn_id.load(.monotonic),
            .segments_count = self.segments.items.len + @as(usize, if (self.current_segment != null) 1 else 0),
            .records_written = self.records_written.load(.monotonic),
            .bytes_written = self.bytes_written.load(.monotonic),
            .syncs_performed = self.syncs_performed.load(.monotonic),
            .checkpoints_created = self.checkpoints_created.load(.monotonic),
        };
    }

    fn ensureActiveSegment(self: *WAL, record_size: usize) !void {
        if (self.current_segment == null or !self.current_segment.?.hasSpace(record_size)) {
            // Seal current segment if exists
            if (self.current_segment) |seg| {
                try seg.seal();
                try self.segments.append(seg);
            }

            // Create new segment
            const segment_id = self.segments.items.len;
            const start_lsn = self.current_lsn.load(.monotonic) + 1;

            const new_segment = try self.allocator.create(WALSegment);
            new_segment.* = try WALSegment.create(
                self.allocator,
                self.dir,
                segment_id,
                start_lsn,
                self.config.segment_size,
            );

            self.current_segment = new_segment;
            log.info("Created new WAL segment {}", .{segment_id});
        }
    }
};

pub const WALStats = struct {
    current_lsn: u64,
    current_txn_id: u64,
    segments_count: usize,
    records_written: u64,
    bytes_written: u64,
    syncs_performed: u64,
    checkpoints_created: u64,
};

// ============================================================================
// CRC32 Checksum
// ============================================================================

fn computeCrc32(data: []const u8) u32 {
    // CRC32C polynomial table (Castagnoli)
    const CRC32_TABLE = generateCrc32Table();

    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc = CRC32_TABLE[@as(usize, @truncate(crc ^ byte))] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
}

fn generateCrc32Table() [256]u32 {
    var table: [256]u32 = undefined;
    const POLY: u32 = 0x82F63B78; // CRC32C polynomial

    for (0..256) |i| {
        var crc: u32 = @intCast(i);
        for (0..8) |_| {
            if ((crc & 1) != 0) {
                crc = (crc >> 1) ^ POLY;
            } else {
                crc >>= 1;
            }
        }
        table[i] = crc;
    }
    return table;
}

// ============================================================================
// WAL-Specific Payloads
// ============================================================================

pub const TopicCreatedPayload = struct {
    name_len: u16,
    name: []const u8,
    partitions: u16,
    replication_factor: u8,

    pub fn serialize(self: *const TopicCreatedPayload, allocator: std.mem.Allocator) ![]u8 {
        const size = 5 + self.name.len;
        var buf = try allocator.alloc(u8, size);

        std.mem.writeInt(u16, buf[0..2], self.name_len, .little);
        @memcpy(buf[2..][0..self.name.len], self.name);
        std.mem.writeInt(u16, buf[2 + self.name.len ..][0..2], self.partitions, .little);
        buf[4 + self.name.len] = self.replication_factor;

        return buf;
    }
};

pub const CursorUpdatedPayload = struct {
    topic_name_len: u16,
    topic_name: []const u8,
    subscription_name_len: u16,
    subscription_name: []const u8,
    ledger_id: i64,
    entry_id: i64,

    pub fn serialize(self: *const CursorUpdatedPayload, allocator: std.mem.Allocator) ![]u8 {
        const size = 4 + self.topic_name.len + self.subscription_name.len + 16;
        var buf = try allocator.alloc(u8, size);
        var offset: usize = 0;

        std.mem.writeInt(u16, buf[offset..][0..2], self.topic_name_len, .little);
        offset += 2;
        @memcpy(buf[offset..][0..self.topic_name.len], self.topic_name);
        offset += self.topic_name.len;

        std.mem.writeInt(u16, buf[offset..][0..2], self.subscription_name_len, .little);
        offset += 2;
        @memcpy(buf[offset..][0..self.subscription_name.len], self.subscription_name);
        offset += self.subscription_name.len;

        std.mem.writeInt(i64, buf[offset..][0..8], self.ledger_id, .little);
        offset += 8;
        std.mem.writeInt(i64, buf[offset..][0..8], self.entry_id, .little);

        return buf;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "WALRecord serialize/deserialize" {
    const allocator = std.testing.allocator;

    const payload = "test payload data";
    const record = WALRecord{
        .lsn = 12345,
        .record_type = .TopicCreated,
        .txn_id = 100,
        .timestamp = 1234567890,
        .checksum = computeCrc32(payload),
        .payload_len = @intCast(payload.len),
        .payload = payload,
    };

    var buffer: [256]u8 = undefined;
    const written = try record.serialize(&buffer);

    const restored = try WALRecord.deserialize(buffer[0..written], allocator);
    defer allocator.free(restored.payload);

    try std.testing.expectEqual(record.lsn, restored.lsn);
    try std.testing.expectEqual(record.record_type, restored.record_type);
    try std.testing.expectEqual(record.txn_id, restored.txn_id);
    try std.testing.expectEqualStrings(payload, restored.payload);
}

test "computeCrc32" {
    const data1 = "hello";
    const data2 = "hello";
    const data3 = "world";

    const crc1 = computeCrc32(data1);
    const crc2 = computeCrc32(data2);
    const crc3 = computeCrc32(data3);

    try std.testing.expectEqual(crc1, crc2);
    try std.testing.expect(crc1 != crc3);
}

test "RecordType values" {
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(RecordType.BeginTxn));
    try std.testing.expectEqual(@as(u8, 0x10), @intFromEnum(RecordType.TopicCreated));
    try std.testing.expectEqual(@as(u8, 0x50), @intFromEnum(RecordType.Checkpoint));
}