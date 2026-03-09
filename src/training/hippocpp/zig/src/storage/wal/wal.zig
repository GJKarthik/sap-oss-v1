//! WAL - Write-Ahead Logging
//!
//! Converted from: kuzu/src/storage/wal/wal.cpp
//!
//! Purpose:
//! Provides write-ahead logging for crash recovery and durability.
//! Ensures ACID properties by logging all modifications before they
//! are applied to the main database file.

const std = @import("std");
const common = @import("common");
const file_handle = @import("file_handle");

const PageIdx = common.PageIdx;
const TableID = common.TableID;
const StorageConstants = common.StorageConstants;
const KUZU_PAGE_SIZE = common.KUZU_PAGE_SIZE;

/// Log Sequence Number
pub const LSN = u64;
pub const INVALID_LSN: LSN = 0;

/// WAL record types
pub const WALRecordType = enum(u8) {
    INVALID = 0,
    PAGE_UPDATE = 1,
    COMMIT = 2,
    CHECKPOINT_BEGIN = 3,
    CHECKPOINT_END = 4,
    CREATE_TABLE = 5,
    DROP_TABLE = 6,
    INSERT = 7,
    UPDATE = 8,
    DELETE = 9,
};

/// WAL record header
pub const WALRecordHeader = struct {
    lsn: LSN,
    record_type: WALRecordType,
    table_id: TableID,
    page_idx: PageIdx,
    tx_id: u64,
    data_size: u32,
    checksum: u32,
    
    pub const SIZE: usize = 48;
    
    pub fn serialize(self: *const WALRecordHeader, buf: []u8) void {
        std.mem.writeInt(u64, buf[0..8], self.lsn, .little);
        buf[8] = @intFromEnum(self.record_type);
        std.mem.writeInt(u64, buf[9..17], self.table_id, .little);
        std.mem.writeInt(u64, buf[17..25], self.page_idx, .little);
        std.mem.writeInt(u64, buf[25..33], self.tx_id, .little);
        std.mem.writeInt(u32, buf[33..37], self.data_size, .little);
        std.mem.writeInt(u32, buf[37..41], self.checksum, .little);
    }
    
    pub fn deserialize(buf: []const u8) WALRecordHeader {
        return WALRecordHeader{
            .lsn = std.mem.readInt(u64, buf[0..8], .little),
            .record_type = @enumFromInt(buf[8]),
            .table_id = std.mem.readInt(u64, buf[9..17], .little),
            .page_idx = std.mem.readInt(u64, buf[17..25], .little),
            .tx_id = std.mem.readInt(u64, buf[25..33], .little),
            .data_size = std.mem.readInt(u32, buf[33..37], .little),
            .checksum = std.mem.readInt(u32, buf[37..41], .little),
        };
    }
};

/// WAL record with data
pub const WALRecord = struct {
    header: WALRecordHeader,
    data: []u8,
    
    pub fn deinit(self: *WALRecord, allocator: std.mem.Allocator) void {
        if (self.data.len > 0) {
            allocator.free(self.data);
        }
    }
};

/// Write-Ahead Log
pub const WAL = struct {
    allocator: std.mem.Allocator,
    
    /// WAL file path
    path: []const u8,
    
    /// WAL file handle
    fh: ?*file_handle.FileHandle,
    
    /// Current LSN (next to assign)
    current_lsn: LSN,
    
    /// Flushed LSN (last synced to disk)
    flushed_lsn: LSN,
    
    /// Checkpoint LSN
    checkpoint_lsn: LSN,
    
    /// Write buffer
    buffer: std.ArrayList(u8),
    
    /// Buffer size threshold for flushing
    flush_threshold: usize,
    
    /// Enable checksums
    checksums_enabled: bool,
    
    /// Mutex for thread safety
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    const DEFAULT_FLUSH_THRESHOLD: usize = 1024 * 1024; // 1MB
    
    /// Create a new WAL
    pub fn create(allocator: std.mem.Allocator, path: []const u8) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .fh = null,
            .current_lsn = 1,
            .flushed_lsn = 0,
            .checkpoint_lsn = 0,
            .buffer = .{},
            .flush_threshold = DEFAULT_FLUSH_THRESHOLD,
            .checksums_enabled = true,
            .mutex = .{},
        };
        return self;
    }
    
    /// Open the WAL file
    pub fn open(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.fh != null) return;
        
        self.fh = try file_handle.FileHandle.open(
            self.allocator,
            self.path,
            .{ .create_if_not_exists = true },
        );
    }
    
    /// Log a page update
    pub fn logPageUpdate(self: *Self, table_id: TableID, page_idx: PageIdx, tx_id: u64, data: []const u8) !LSN {
        return self.appendRecord(.PAGE_UPDATE, table_id, page_idx, tx_id, data);
    }
    
    /// Log a commit
    pub fn logCommit(self: *Self, tx_id: u64) !LSN {
        return self.appendRecord(.COMMIT, 0, 0, tx_id, &[_]u8{});
    }
    
    /// Log checkpoint begin
    pub fn logCheckpointBegin(self: *Self) !LSN {
        return self.appendRecord(.CHECKPOINT_BEGIN, 0, 0, 0, &[_]u8{});
    }
    
    /// Log checkpoint end
    pub fn logCheckpointEnd(self: *Self) !LSN {
        const lsn = try self.appendRecord(.CHECKPOINT_END, 0, 0, 0, &[_]u8{});
        self.checkpoint_lsn = lsn;
        return lsn;
    }
    
    /// Append a record to the WAL
    fn appendRecord(self: *Self, record_type: WALRecordType, table_id: TableID, page_idx: PageIdx, tx_id: u64, data: []const u8) !LSN {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const lsn = self.current_lsn;
        self.current_lsn += 1;
        
        const header = WALRecordHeader{
            .lsn = lsn,
            .record_type = record_type,
            .table_id = table_id,
            .page_idx = page_idx,
            .tx_id = tx_id,
            .data_size = @intCast(data.len),
            .checksum = if (self.checksums_enabled) self.computeChecksum(data) else 0,
        };
        
        // Serialize header
        var header_buf: [WALRecordHeader.SIZE]u8 = undefined;
        header.serialize(&header_buf);
        try self.buffer.appendSlice(self.allocator, &header_buf);
        
        // Append data
        if (data.len > 0) {
            try self.buffer.appendSlice(self.allocator, data);
        }
        
        // Flush if buffer exceeds threshold
        if (self.buffer.items.len >= self.flush_threshold) {
            try self.flushBuffer();
        }
        
        return lsn;
    }
    
    /// Compute checksum for data
    fn computeChecksum(self: *Self, data: []const u8) u32 {
        _ = self;
        if (data.len == 0) return 0;
        
        var hash = std.hash.Crc32.init();
        hash.update(data);
        return hash.final();
    }
    
    /// Flush write buffer to disk
    fn flushBuffer(self: *Self) !void {
        if (self.buffer.items.len == 0) return;
        if (self.fh == null) return;
        
        // Write buffer to file
        const fh = self.fh.?;
        const file_size = fh.getFileSize();
        const page_idx: PageIdx = @intCast(file_size / KUZU_PAGE_SIZE);
        
        // Pad to page size
        const padded_size = ((self.buffer.items.len + KUZU_PAGE_SIZE - 1) / KUZU_PAGE_SIZE) * KUZU_PAGE_SIZE;
        try self.buffer.ensureTotalCapacity(padded_size);
        while (self.buffer.items.len < padded_size) {
            try self.buffer.append(self.allocator, 0);
        }
        
        // Write pages
        var offset: usize = 0;
        var current_page = page_idx;
        while (offset < self.buffer.items.len) {
            try fh.writePage(current_page, self.buffer.items[offset..][0..KUZU_PAGE_SIZE]);
            offset += KUZU_PAGE_SIZE;
            current_page += 1;
        }
        
        // Sync
        try fh.sync();
        
        self.flushed_lsn = self.current_lsn - 1;
        self.buffer.clearRetainingCapacity();
    }
    
    /// Flush all pending records
    pub fn flush(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.flushBuffer();
    }
    
    /// Get current LSN
    pub fn getCurrentLSN(self: *Self) LSN {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.current_lsn;
    }
    
    /// Get flushed LSN
    pub fn getFlushedLSN(self: *Self) LSN {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.flushed_lsn;
    }
    
    /// Close the WAL
    pub fn close(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.flushBuffer() catch {};
        
        if (self.fh) |fh| {
            fh.close();
            self.allocator.destroy(fh);
            self.fh = null;
        }
    }
    
    /// Destroy the WAL
    pub fn destroy(self: *Self) void {
        self.close();
        self.buffer.deinit(self.allocator);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "WAL record header serialization" {
    const header = WALRecordHeader{
        .lsn = 42,
        .record_type = .PAGE_UPDATE,
        .table_id = 1,
        .page_idx = 100,
        .tx_id = 5,
        .data_size = 4096,
        .checksum = 12345,
    };
    
    var buf: [WALRecordHeader.SIZE]u8 = undefined;
    header.serialize(&buf);
    
    const deserialized = WALRecordHeader.deserialize(&buf);
    try std.testing.expectEqual(header.lsn, deserialized.lsn);
    try std.testing.expectEqual(header.record_type, deserialized.record_type);
    try std.testing.expectEqual(header.table_id, deserialized.table_id);
    try std.testing.expectEqual(header.page_idx, deserialized.page_idx);
    try std.testing.expectEqual(header.tx_id, deserialized.tx_id);
    try std.testing.expectEqual(header.data_size, deserialized.data_size);
}

test "WAL creation" {
    const allocator = std.testing.allocator;
    
    const wal = try WAL.create(allocator, "/tmp/test.wal");
    defer wal.destroy();
    
    try std.testing.expectEqual(@as(LSN, 1), wal.current_lsn);
    try std.testing.expectEqual(@as(LSN, 0), wal.flushed_lsn);
}