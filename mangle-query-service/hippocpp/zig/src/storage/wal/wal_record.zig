//! WAL Record - Write-Ahead Log record types and serialization
//!
//! Purpose:
//! Defines WAL record types for all database operations,
//! including serialization/deserialization for recovery.

const std = @import("std");

// ============================================================================
// WAL Record Types
// ============================================================================

pub const WalRecordType = enum(u8) {
    // Transaction records
    BEGIN_TRANSACTION = 1,
    COMMIT_TRANSACTION = 2,
    ABORT_TRANSACTION = 3,
    
    // Data modification records
    INSERT_NODE = 10,
    DELETE_NODE = 11,
    UPDATE_NODE = 12,
    INSERT_REL = 13,
    DELETE_REL = 14,
    UPDATE_REL = 15,
    
    // Page-level records
    PAGE_UPDATE = 20,
    PAGE_ALLOCATION = 21,
    PAGE_DEALLOCATION = 22,
    
    // DDL records
    CREATE_TABLE = 30,
    DROP_TABLE = 31,
    ALTER_TABLE = 32,
    CREATE_INDEX = 33,
    DROP_INDEX = 34,
    
    // Checkpoint records
    CHECKPOINT_BEGIN = 40,
    CHECKPOINT_END = 41,
    
    // Compensation records (for undo)
    COMPENSATION = 50,
};

// ============================================================================
// WAL Record Header
// ============================================================================

pub const WalRecordHeader = struct {
    lsn: u64,
    prev_lsn: u64,
    transaction_id: u64,
    record_type: WalRecordType,
    data_length: u32,
    checksum: u32,
    
    pub const HEADER_SIZE: usize = 8 + 8 + 8 + 1 + 4 + 4;  // 33 bytes
    
    pub fn init(lsn: u64, tx_id: u64, record_type: WalRecordType) WalRecordHeader {
        return .{
            .lsn = lsn,
            .prev_lsn = 0,
            .transaction_id = tx_id,
            .record_type = record_type,
            .data_length = 0,
            .checksum = 0,
        };
    }
    
    pub fn serialize(self: *const WalRecordHeader, buffer: []u8) !usize {
        if (buffer.len < HEADER_SIZE) return error.BufferTooSmall;
        
        var pos: usize = 0;
        std.mem.writeInt(u64, buffer[pos..][0..8], self.lsn, .little);
        pos += 8;
        std.mem.writeInt(u64, buffer[pos..][0..8], self.prev_lsn, .little);
        pos += 8;
        std.mem.writeInt(u64, buffer[pos..][0..8], self.transaction_id, .little);
        pos += 8;
        buffer[pos] = @intFromEnum(self.record_type);
        pos += 1;
        std.mem.writeInt(u32, buffer[pos..][0..4], self.data_length, .little);
        pos += 4;
        std.mem.writeInt(u32, buffer[pos..][0..4], self.checksum, .little);
        pos += 4;
        
        return pos;
    }
    
    pub fn deserialize(buffer: []const u8) !WalRecordHeader {
        if (buffer.len < HEADER_SIZE) return error.BufferTooSmall;
        
        var pos: usize = 0;
        const lsn = std.mem.readInt(u64, buffer[pos..][0..8], .little);
        pos += 8;
        const prev_lsn = std.mem.readInt(u64, buffer[pos..][0..8], .little);
        pos += 8;
        const tx_id = std.mem.readInt(u64, buffer[pos..][0..8], .little);
        pos += 8;
        const record_type: WalRecordType = @enumFromInt(buffer[pos]);
        pos += 1;
        const data_length = std.mem.readInt(u32, buffer[pos..][0..4], .little);
        pos += 4;
        const checksum = std.mem.readInt(u32, buffer[pos..][0..4], .little);
        
        return .{
            .lsn = lsn,
            .prev_lsn = prev_lsn,
            .transaction_id = tx_id,
            .record_type = record_type,
            .data_length = data_length,
            .checksum = checksum,
        };
    }
};

// ============================================================================
// Specific WAL Record Types
// ============================================================================

pub const BeginTransactionRecord = struct {
    transaction_id: u64,
    isolation_level: u8,
    read_only: bool,
    
    pub fn serialize(self: *const BeginTransactionRecord, buffer: []u8) !usize {
        if (buffer.len < 10) return error.BufferTooSmall;
        std.mem.writeInt(u64, buffer[0..8], self.transaction_id, .little);
        buffer[8] = self.isolation_level;
        buffer[9] = if (self.read_only) 1 else 0;
        return 10;
    }
    
    pub fn deserialize(buffer: []const u8) !BeginTransactionRecord {
        if (buffer.len < 10) return error.BufferTooSmall;
        return .{
            .transaction_id = std.mem.readInt(u64, buffer[0..8], .little),
            .isolation_level = buffer[8],
            .read_only = buffer[9] != 0,
        };
    }
};

pub const CommitTransactionRecord = struct {
    transaction_id: u64,
    commit_timestamp: i64,
    
    pub fn serialize(self: *const CommitTransactionRecord, buffer: []u8) !usize {
        if (buffer.len < 16) return error.BufferTooSmall;
        std.mem.writeInt(u64, buffer[0..8], self.transaction_id, .little);
        std.mem.writeInt(i64, buffer[8..16], self.commit_timestamp, .little);
        return 16;
    }
    
    pub fn deserialize(buffer: []const u8) !CommitTransactionRecord {
        if (buffer.len < 16) return error.BufferTooSmall;
        return .{
            .transaction_id = std.mem.readInt(u64, buffer[0..8], .little),
            .commit_timestamp = std.mem.readInt(i64, buffer[8..16], .little),
        };
    }
};

pub const InsertNodeRecord = struct {
    table_id: u64,
    node_offset: u64,
    data_offset: u32,
    data_length: u32,
    // Data follows in the record
    
    pub fn serialize(self: *const InsertNodeRecord, buffer: []u8) !usize {
        if (buffer.len < 24) return error.BufferTooSmall;
        std.mem.writeInt(u64, buffer[0..8], self.table_id, .little);
        std.mem.writeInt(u64, buffer[8..16], self.node_offset, .little);
        std.mem.writeInt(u32, buffer[16..20], self.data_offset, .little);
        std.mem.writeInt(u32, buffer[20..24], self.data_length, .little);
        return 24;
    }
    
    pub fn deserialize(buffer: []const u8) !InsertNodeRecord {
        if (buffer.len < 24) return error.BufferTooSmall;
        return .{
            .table_id = std.mem.readInt(u64, buffer[0..8], .little),
            .node_offset = std.mem.readInt(u64, buffer[8..16], .little),
            .data_offset = std.mem.readInt(u32, buffer[16..20], .little),
            .data_length = std.mem.readInt(u32, buffer[20..24], .little),
        };
    }
};

pub const DeleteNodeRecord = struct {
    table_id: u64,
    node_offset: u64,
    
    pub fn serialize(self: *const DeleteNodeRecord, buffer: []u8) !usize {
        if (buffer.len < 16) return error.BufferTooSmall;
        std.mem.writeInt(u64, buffer[0..8], self.table_id, .little);
        std.mem.writeInt(u64, buffer[8..16], self.node_offset, .little);
        return 16;
    }
    
    pub fn deserialize(buffer: []const u8) !DeleteNodeRecord {
        if (buffer.len < 16) return error.BufferTooSmall;
        return .{
            .table_id = std.mem.readInt(u64, buffer[0..8], .little),
            .node_offset = std.mem.readInt(u64, buffer[8..16], .little),
        };
    }
};

pub const InsertRelRecord = struct {
    table_id: u64,
    src_node: u64,
    dst_node: u64,
    rel_offset: u64,
    
    pub fn serialize(self: *const InsertRelRecord, buffer: []u8) !usize {
        if (buffer.len < 32) return error.BufferTooSmall;
        std.mem.writeInt(u64, buffer[0..8], self.table_id, .little);
        std.mem.writeInt(u64, buffer[8..16], self.src_node, .little);
        std.mem.writeInt(u64, buffer[16..24], self.dst_node, .little);
        std.mem.writeInt(u64, buffer[24..32], self.rel_offset, .little);
        return 32;
    }
    
    pub fn deserialize(buffer: []const u8) !InsertRelRecord {
        if (buffer.len < 32) return error.BufferTooSmall;
        return .{
            .table_id = std.mem.readInt(u64, buffer[0..8], .little),
            .src_node = std.mem.readInt(u64, buffer[8..16], .little),
            .dst_node = std.mem.readInt(u64, buffer[16..24], .little),
            .rel_offset = std.mem.readInt(u64, buffer[24..32], .little),
        };
    }
};

pub const PageUpdateRecord = struct {
    page_id: u64,
    offset: u32,
    old_length: u32,
    new_length: u32,
    // Old data and new data follow
    
    pub fn serialize(self: *const PageUpdateRecord, buffer: []u8) !usize {
        if (buffer.len < 20) return error.BufferTooSmall;
        std.mem.writeInt(u64, buffer[0..8], self.page_id, .little);
        std.mem.writeInt(u32, buffer[8..12], self.offset, .little);
        std.mem.writeInt(u32, buffer[12..16], self.old_length, .little);
        std.mem.writeInt(u32, buffer[16..20], self.new_length, .little);
        return 20;
    }
    
    pub fn deserialize(buffer: []const u8) !PageUpdateRecord {
        if (buffer.len < 20) return error.BufferTooSmall;
        return .{
            .page_id = std.mem.readInt(u64, buffer[0..8], .little),
            .offset = std.mem.readInt(u32, buffer[8..12], .little),
            .old_length = std.mem.readInt(u32, buffer[12..16], .little),
            .new_length = std.mem.readInt(u32, buffer[16..20], .little),
        };
    }
};

pub const CheckpointRecord = struct {
    checkpoint_id: u64,
    active_tx_count: u32,
    dirty_page_count: u32,
    
    pub fn serialize(self: *const CheckpointRecord, buffer: []u8) !usize {
        if (buffer.len < 16) return error.BufferTooSmall;
        std.mem.writeInt(u64, buffer[0..8], self.checkpoint_id, .little);
        std.mem.writeInt(u32, buffer[8..12], self.active_tx_count, .little);
        std.mem.writeInt(u32, buffer[12..16], self.dirty_page_count, .little);
        return 16;
    }
    
    pub fn deserialize(buffer: []const u8) !CheckpointRecord {
        if (buffer.len < 16) return error.BufferTooSmall;
        return .{
            .checkpoint_id = std.mem.readInt(u64, buffer[0..8], .little),
            .active_tx_count = std.mem.readInt(u32, buffer[8..12], .little),
            .dirty_page_count = std.mem.readInt(u32, buffer[12..16], .little),
        };
    }
};

// ============================================================================
// WAL Record (Complete record with header and data)
// ============================================================================

pub const WalRecord = struct {
    header: WalRecordHeader,
    data: []const u8,
    
    pub fn totalSize(self: *const WalRecord) usize {
        return WalRecordHeader.HEADER_SIZE + self.data.len;
    }
    
    pub fn computeChecksum(self: *const WalRecord) u32 {
        return std.hash.Crc32.hash(self.data);
    }
    
    pub fn verify(self: *const WalRecord) bool {
        return self.computeChecksum() == self.header.checksum;
    }
};

// ============================================================================
// WAL Record Builder
// ============================================================================

pub const WalRecordBuilder = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    current_lsn: u64,
    
    pub fn init(allocator: std.mem.Allocator) WalRecordBuilder {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
            .current_lsn = 0,
        };
    }
    
    pub fn deinit(self: *WalRecordBuilder) void {
        self.buffer.deinit();
    }
    
    pub fn buildBeginTransaction(self: *WalRecordBuilder, tx_id: u64, isolation: u8, read_only: bool) !WalRecord {
        self.buffer.clearRetainingCapacity();
        
        const record = BeginTransactionRecord{
            .transaction_id = tx_id,
            .isolation_level = isolation,
            .read_only = read_only,
        };
        
        try self.buffer.resize(10);
        _ = try record.serialize(self.buffer.items);
        
        self.current_lsn += 1;
        var header = WalRecordHeader.init(self.current_lsn, tx_id, .BEGIN_TRANSACTION);
        header.data_length = @intCast(self.buffer.items.len);
        header.checksum = std.hash.Crc32.hash(self.buffer.items);
        
        return WalRecord{
            .header = header,
            .data = self.buffer.items,
        };
    }
    
    pub fn buildCommitTransaction(self: *WalRecordBuilder, tx_id: u64) !WalRecord {
        self.buffer.clearRetainingCapacity();
        
        const record = CommitTransactionRecord{
            .transaction_id = tx_id,
            .commit_timestamp = std.time.timestamp(),
        };
        
        try self.buffer.resize(16);
        _ = try record.serialize(self.buffer.items);
        
        self.current_lsn += 1;
        var header = WalRecordHeader.init(self.current_lsn, tx_id, .COMMIT_TRANSACTION);
        header.data_length = @intCast(self.buffer.items.len);
        header.checksum = std.hash.Crc32.hash(self.buffer.items);
        
        return WalRecord{
            .header = header,
            .data = self.buffer.items,
        };
    }
    
    pub fn buildInsertNode(self: *WalRecordBuilder, tx_id: u64, table_id: u64, node_offset: u64, data: []const u8) !WalRecord {
        self.buffer.clearRetainingCapacity();
        
        const meta = InsertNodeRecord{
            .table_id = table_id,
            .node_offset = node_offset,
            .data_offset = 24,
            .data_length = @intCast(data.len),
        };
        
        try self.buffer.resize(24 + data.len);
        _ = try meta.serialize(self.buffer.items);
        @memcpy(self.buffer.items[24..], data);
        
        self.current_lsn += 1;
        var header = WalRecordHeader.init(self.current_lsn, tx_id, .INSERT_NODE);
        header.data_length = @intCast(self.buffer.items.len);
        header.checksum = std.hash.Crc32.hash(self.buffer.items);
        
        return WalRecord{
            .header = header,
            .data = self.buffer.items,
        };
    }
    
    pub fn getCurrentLSN(self: *const WalRecordBuilder) u64 {
        return self.current_lsn;
    }
};

// ============================================================================
// WAL Iterator
// ============================================================================

pub const WalIterator = struct {
    data: []const u8,
    position: usize = 0,
    
    pub fn init(data: []const u8) WalIterator {
        return .{ .data = data };
    }
    
    pub fn next(self: *WalIterator) !?WalRecord {
        if (self.position >= self.data.len) return null;
        
        const remaining = self.data[self.position..];
        if (remaining.len < WalRecordHeader.HEADER_SIZE) return null;
        
        const header = try WalRecordHeader.deserialize(remaining);
        const record_end = WalRecordHeader.HEADER_SIZE + header.data_length;
        
        if (remaining.len < record_end) return error.IncompleteRecord;
        
        const record = WalRecord{
            .header = header,
            .data = remaining[WalRecordHeader.HEADER_SIZE..record_end],
        };
        
        self.position += record_end;
        return record;
    }
    
    pub fn reset(self: *WalIterator) void {
        self.position = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "wal record header serialize deserialize" {
    var header = WalRecordHeader.init(100, 1, .INSERT_NODE);
    header.data_length = 50;
    header.checksum = 12345;
    
    var buffer: [WalRecordHeader.HEADER_SIZE]u8 = undefined;
    const written = try header.serialize(&buffer);
    
    try std.testing.expectEqual(@as(usize, WalRecordHeader.HEADER_SIZE), written);
    
    const decoded = try WalRecordHeader.deserialize(&buffer);
    try std.testing.expectEqual(@as(u64, 100), decoded.lsn);
    try std.testing.expectEqual(@as(u64, 1), decoded.transaction_id);
    try std.testing.expectEqual(WalRecordType.INSERT_NODE, decoded.record_type);
    try std.testing.expectEqual(@as(u32, 50), decoded.data_length);
}

test "begin transaction record" {
    const record = BeginTransactionRecord{
        .transaction_id = 42,
        .isolation_level = 2,
        .read_only = true,
    };
    
    var buffer: [10]u8 = undefined;
    _ = try record.serialize(&buffer);
    
    const decoded = try BeginTransactionRecord.deserialize(&buffer);
    try std.testing.expectEqual(@as(u64, 42), decoded.transaction_id);
    try std.testing.expectEqual(@as(u8, 2), decoded.isolation_level);
    try std.testing.expect(decoded.read_only);
}

test "insert node record" {
    const record = InsertNodeRecord{
        .table_id = 1,
        .node_offset = 100,
        .data_offset = 24,
        .data_length = 50,
    };
    
    var buffer: [24]u8 = undefined;
    _ = try record.serialize(&buffer);
    
    const decoded = try InsertNodeRecord.deserialize(&buffer);
    try std.testing.expectEqual(@as(u64, 1), decoded.table_id);
    try std.testing.expectEqual(@as(u64, 100), decoded.node_offset);
}

test "wal record builder" {
    const allocator = std.testing.allocator;
    
    var builder = WalRecordBuilder.init(allocator);
    defer builder.deinit();
    
    const record = try builder.buildBeginTransaction(1, 0, false);
    try std.testing.expectEqual(@as(u64, 1), record.header.lsn);
    try std.testing.expectEqual(WalRecordType.BEGIN_TRANSACTION, record.header.record_type);
    try std.testing.expect(record.verify());
}

test "wal record type enum" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(WalRecordType.BEGIN_TRANSACTION));
    try std.testing.expectEqual(@as(u8, 10), @intFromEnum(WalRecordType.INSERT_NODE));
    try std.testing.expectEqual(@as(u8, 40), @intFromEnum(WalRecordType.CHECKPOINT_BEGIN));
}