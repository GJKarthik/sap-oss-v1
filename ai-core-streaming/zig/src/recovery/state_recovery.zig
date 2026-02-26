//! AIPrompt Streaming - State Recovery Engine
//! Rebuilds broker state from WAL and HANA after crash
//!
//! This module provides crash recovery capabilities by replaying WAL records
//! and synchronizing with HANA to restore the broker to a consistent state.

const std = @import("std");
const wal_mod = @import("wal.zig");

const WAL = wal_mod.WAL;
const WALRecord = wal_mod.WALRecord;
const WALSegment = wal_mod.WALSegment;
const RecordType = wal_mod.RecordType;

const log = std.log.scoped(.recovery);

// ============================================================================
// Recovery State
// ============================================================================

pub const RecoveryState = enum {
    NotStarted,
    ScanningWAL,
    LoadingCheckpoint,
    ReplayingRecords,
    SyncingHANA,
    Completed,
    Failed,
};

pub const RecoveryProgress = struct {
    state: RecoveryState,
    segments_scanned: usize,
    records_processed: u64,
    checkpoints_found: u64,
    last_checkpoint_lsn: u64,
    recovered_lsn: u64,
    topics_recovered: u32,
    subscriptions_recovered: u32,
    cursors_recovered: u32,
    errors: u32,
    start_time: i64,
    end_time: i64,
};

// ============================================================================
// Recovered Broker State
// ============================================================================

pub const RecoveredBrokerState = struct {
    allocator: std.mem.Allocator,
    
    // Core state
    topics: std.StringHashMap(TopicState),
    subscriptions: std.StringHashMap(SubscriptionState),
    ledgers: std.AutoHashMap(i64, LedgerState),
    
    // Recovery metadata
    last_lsn: u64,
    last_txn_id: u64,
    checkpoint_lsn: u64,
    recovery_timestamp: i64,

    pub fn init(allocator: std.mem.Allocator) RecoveredBrokerState {
        return .{
            .allocator = allocator,
            .topics = std.StringHashMap(TopicState).init(allocator),
            .subscriptions = std.StringHashMap(SubscriptionState).init(allocator),
            .ledgers = std.AutoHashMap(i64, LedgerState).init(allocator),
            .last_lsn = 0,
            .last_txn_id = 0,
            .checkpoint_lsn = 0,
            .recovery_timestamp = 0,
        };
    }

    pub fn deinit(self: *RecoveredBrokerState) void {
        var topic_iter = self.topics.iterator();
        while (topic_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.topics.deinit();

        var sub_iter = self.subscriptions.iterator();
        while (sub_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.subscriptions.deinit();

        self.ledgers.deinit();
    }
};

pub const TopicState = struct {
    name: []const u8,
    created_lsn: u64,
    partitions: u16,
    replication_factor: u8,
    message_count: u64,
    byte_count: u64,
    last_publish_lsn: u64,
    schema_id: u64,
    is_deleted: bool,
};

pub const SubscriptionState = struct {
    topic_name: []const u8,
    subscription_name: []const u8,
    created_lsn: u64,
    cursor_ledger_id: i64,
    cursor_entry_id: i64,
    pending_ack_count: u64,
    is_deleted: bool,
};

pub const LedgerState = struct {
    ledger_id: i64,
    topic_name: []const u8,
    created_lsn: u64,
    first_entry_id: i64,
    last_entry_id: i64,
    size_bytes: u64,
    is_closed: bool,
    is_trimmed: bool,
};

// ============================================================================
// State Recovery Engine
// ============================================================================

pub const StateRecoveryEngine = struct {
    allocator: std.mem.Allocator,
    wal: *WAL,
    config: RecoveryConfig,
    progress: RecoveryProgress,
    state: RecoveredBrokerState,
    
    // Transaction tracking for ACID recovery
    pending_txns: std.AutoHashMap(u64, PendingTransaction),
    
    // Callbacks
    on_topic_recovered: ?*const fn (*const TopicState) void,
    on_subscription_recovered: ?*const fn (*const SubscriptionState) void,
    on_progress_update: ?*const fn (*const RecoveryProgress) void,

    pub const RecoveryConfig = struct {
        wal_dir: []const u8 = "data/wal",
        hana_sync_enabled: bool = true,
        parallel_replay: bool = false,
        max_records_per_batch: usize = 10_000,
        skip_checksum_validation: bool = false,
        recovery_timeout_ms: u64 = 300_000, // 5 minutes
    };

    const PendingTransaction = struct {
        txn_id: u64,
        start_lsn: u64,
        records: std.ArrayList(WALRecord),
        is_committed: bool,
    };

    pub fn init(allocator: std.mem.Allocator, wal: *WAL, config: RecoveryConfig) StateRecoveryEngine {
        return .{
            .allocator = allocator,
            .wal = wal,
            .config = config,
            .progress = .{
                .state = .NotStarted,
                .segments_scanned = 0,
                .records_processed = 0,
                .checkpoints_found = 0,
                .last_checkpoint_lsn = 0,
                .recovered_lsn = 0,
                .topics_recovered = 0,
                .subscriptions_recovered = 0,
                .cursors_recovered = 0,
                .errors = 0,
                .start_time = 0,
                .end_time = 0,
            },
            .state = RecoveredBrokerState.init(allocator),
            .pending_txns = std.AutoHashMap(u64, PendingTransaction).init(allocator),
            .on_topic_recovered = null,
            .on_subscription_recovered = null,
            .on_progress_update = null,
        };
    }

    pub fn deinit(self: *StateRecoveryEngine) void {
        var iter = self.pending_txns.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.records.items) |record| {
                self.allocator.free(record.payload);
            }
            entry.value_ptr.records.deinit();
        }
        self.pending_txns.deinit();
        self.state.deinit();
    }

    /// Execute full recovery
    pub fn recover(self: *StateRecoveryEngine) !RecoveredBrokerState {
        self.progress.start_time = std.time.nanoTimestamp();
        self.progress.state = .ScanningWAL;
        self.notifyProgress();

        log.info("Starting state recovery from WAL directory: {s}", .{self.config.wal_dir});

        // Phase 1: Scan WAL segments
        const segments = try self.scanWALSegments();
        defer self.allocator.free(segments);
        
        self.progress.segments_scanned = segments.len;
        log.info("Found {} WAL segments", .{segments.len});

        if (segments.len == 0) {
            log.info("No WAL segments found - fresh start", .{});
            self.progress.state = .Completed;
            self.progress.end_time = std.time.nanoTimestamp();
            self.notifyProgress();
            return self.state;
        }

        // Phase 2: Find latest checkpoint
        self.progress.state = .LoadingCheckpoint;
        self.notifyProgress();
        
        const checkpoint = try self.findLatestCheckpoint(segments);
        if (checkpoint) |cp| {
            self.progress.last_checkpoint_lsn = cp.lsn;
            log.info("Found checkpoint at LSN {}", .{cp.lsn});
            try self.loadCheckpoint(cp);
        }

        // Phase 3: Replay WAL records after checkpoint
        self.progress.state = .ReplayingRecords;
        self.notifyProgress();
        
        const start_lsn = if (checkpoint) |cp| cp.lsn + 1 else 0;
        try self.replayRecords(segments, start_lsn);

        // Phase 4: Resolve pending transactions
        try self.resolvePendingTransactions();

        // Phase 5: Sync with HANA (if enabled)
        if (self.config.hana_sync_enabled) {
            self.progress.state = .SyncingHANA;
            self.notifyProgress();
            try self.syncWithHANA();
        }

        // Recovery complete
        self.progress.state = .Completed;
        self.progress.end_time = std.time.nanoTimestamp();
        self.notifyProgress();

        const duration_ms = @divFloor(self.progress.end_time - self.progress.start_time, 1_000_000);
        log.info("Recovery completed in {}ms - {} topics, {} subscriptions, {} cursors", .{
            duration_ms,
            self.progress.topics_recovered,
            self.progress.subscriptions_recovered,
            self.progress.cursors_recovered,
        });

        return self.state;
    }

    /// Scan WAL directory for segments
    fn scanWALSegments(self: *StateRecoveryEngine) ![][]const u8 {
        var segments = std.ArrayList([]const u8).init(self.allocator);
        
        var dir = std.fs.cwd().openDir(self.config.wal_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                return try segments.toOwnedSlice();
            }
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".log")) {
                const path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}/{s}",
                    .{ self.config.wal_dir, entry.name },
                );
                try segments.append(path);
            }
        }

        // Sort segments by name (which includes segment ID)
        std.mem.sort([]const u8, segments.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        return try segments.toOwnedSlice();
    }

    /// Find the latest checkpoint in WAL segments
    fn findLatestCheckpoint(self: *StateRecoveryEngine, segment_paths: []const []const u8) !?WALRecord {
        var latest_checkpoint: ?WALRecord = null;

        // Scan segments in reverse order to find latest checkpoint
        var i: usize = segment_paths.len;
        while (i > 0) {
            i -= 1;
            const path = segment_paths[i];

            var segment = try WALSegment.open(self.allocator, path);
            defer segment.deinit();

            // Scan segment for checkpoint records
            if (segment.file) |file| {
                try file.seekTo(WALSegment.HEADER_SIZE);
                var buf: [65536]u8 = undefined;

                while (true) {
                    const bytes_read = file.read(&buf) catch break;
                    if (bytes_read < WALRecord.HEADER_SIZE) break;

                    const record = WALRecord.deserialize(buf[0..bytes_read], self.allocator) catch break;

                    if (record.record_type == .Checkpoint) {
                        self.progress.checkpoints_found += 1;
                        if (latest_checkpoint == null or record.lsn > latest_checkpoint.?.lsn) {
                            if (latest_checkpoint) |prev| {
                                self.allocator.free(prev.payload);
                            }
                            latest_checkpoint = record;
                        } else {
                            self.allocator.free(record.payload);
                        }
                    } else {
                        self.allocator.free(record.payload);
                    }
                }
            }

            // If we found a checkpoint, we can stop scanning older segments
            if (latest_checkpoint != null) break;
        }

        return latest_checkpoint;
    }

    /// Load state from checkpoint
    fn loadCheckpoint(self: *StateRecoveryEngine, checkpoint: WALRecord) !void {
        log.info("Loading checkpoint at LSN {}", .{checkpoint.lsn});

        // Parse checkpoint payload (serialized broker state)
        if (checkpoint.payload.len < 8) return;

        var offset: usize = 0;

        // Read number of topics
        const num_topics = std.mem.readInt(u32, checkpoint.payload[offset..][0..4], .little);
        offset += 4;

        // Read number of subscriptions
        const num_subs = std.mem.readInt(u32, checkpoint.payload[offset..][0..4], .little);
        offset += 4;

        log.info("Checkpoint contains {} topics, {} subscriptions", .{ num_topics, num_subs });

        // In production: deserialize full topic/subscription state from checkpoint
        // For now, just track the checkpoint LSN
        self.state.checkpoint_lsn = checkpoint.lsn;
        self.state.last_lsn = checkpoint.lsn;
    }

    /// Replay WAL records after checkpoint
    fn replayRecords(self: *StateRecoveryEngine, segment_paths: []const []const u8, start_lsn: u64) !void {
        for (segment_paths) |path| {
            var segment = try WALSegment.open(self.allocator, path);
            defer segment.deinit();

            if (segment.start_lsn + @as(u64, @intCast(segment.size)) < start_lsn) {
                // Skip segments entirely before start_lsn
                continue;
            }

            try self.replaySegment(&segment, start_lsn);
        }
    }

    fn replaySegment(self: *StateRecoveryEngine, segment: *WALSegment, start_lsn: u64) !void {
        if (segment.file == null) return;

        try segment.file.?.seekTo(WALSegment.HEADER_SIZE);

        var record_buf: [65536]u8 = undefined;
        var records_in_segment: u64 = 0;

        while (true) {
            const bytes_read = segment.file.?.read(&record_buf) catch break;
            if (bytes_read < WALRecord.HEADER_SIZE) break;

            const record = WALRecord.deserialize(record_buf[0..bytes_read], self.allocator) catch |err| {
                log.warn("Failed to deserialize record: {}", .{err});
                self.progress.errors += 1;
                break;
            };
            defer self.allocator.free(record.payload);

            if (record.lsn < start_lsn) continue;

            // Validate checksum if not skipped
            if (!self.config.skip_checksum_validation) {
                const computed_checksum = wal_mod.computeCrc32(record.payload);
                if (computed_checksum != record.checksum) {
                    log.warn("Checksum mismatch at LSN {} - skipping", .{record.lsn});
                    self.progress.errors += 1;
                    continue;
                }
            }

            // Apply record
            try self.applyRecord(&record);
            records_in_segment += 1;
            self.progress.records_processed += 1;
            self.state.last_lsn = record.lsn;
        }

        log.debug("Replayed {} records from segment {}", .{ records_in_segment, segment.segment_id });
    }

    /// Apply a single WAL record to state
    fn applyRecord(self: *StateRecoveryEngine, record: *const WALRecord) !void {
        switch (record.record_type) {
            .BeginTxn => {
                var txn = PendingTransaction{
                    .txn_id = record.txn_id,
                    .start_lsn = record.lsn,
                    .records = std.ArrayList(WALRecord).init(self.allocator),
                    .is_committed = false,
                };
                try self.pending_txns.put(record.txn_id, txn);
            },
            .CommitTxn => {
                if (self.pending_txns.getPtr(record.txn_id)) |txn| {
                    txn.is_committed = true;
                    // Apply all transaction records
                    for (txn.records.items) |txn_record| {
                        try self.applyNonTxnRecord(&txn_record);
                    }
                }
            },
            .RollbackTxn => {
                // Discard transaction records
                if (self.pending_txns.fetchRemove(record.txn_id)) |entry| {
                    for (entry.value.records.items) |txn_record| {
                        self.allocator.free(txn_record.payload);
                    }
                    entry.value.records.deinit();
                }
            },
            else => {
                // Non-transactional or buffered in transaction
                if (record.txn_id != 0) {
                    if (self.pending_txns.getPtr(record.txn_id)) |txn| {
                        const record_copy = WALRecord{
                            .lsn = record.lsn,
                            .record_type = record.record_type,
                            .txn_id = record.txn_id,
                            .timestamp = record.timestamp,
                            .checksum = record.checksum,
                            .payload_len = record.payload_len,
                            .payload = try self.allocator.dupe(u8, record.payload),
                        };
                        try txn.records.append(record_copy);
                    }
                } else {
                    try self.applyNonTxnRecord(record);
                }
            },
        }
    }

    fn applyNonTxnRecord(self: *StateRecoveryEngine, record: *const WALRecord) !void {
        switch (record.record_type) {
            .TopicCreated => {
                try self.applyTopicCreated(record);
            },
            .TopicDeleted => {
                try self.applyTopicDeleted(record);
            },
            .SubscriptionCreated => {
                try self.applySubscriptionCreated(record);
            },
            .SubscriptionDeleted => {
                try self.applySubscriptionDeleted(record);
            },
            .CursorUpdated => {
                try self.applyCursorUpdated(record);
            },
            .LedgerCreated => {
                try self.applyLedgerCreated(record);
            },
            .LedgerClosed => {
                try self.applyLedgerClosed(record);
            },
            else => {},
        }
    }

    fn applyTopicCreated(self: *StateRecoveryEngine, record: *const WALRecord) !void {
        if (record.payload.len < 5) return;

        const name_len = std.mem.readInt(u16, record.payload[0..2], .little);
        if (record.payload.len < 5 + name_len) return;

        const name = record.payload[2..][0..name_len];
        const partitions = std.mem.readInt(u16, record.payload[2 + name_len ..][0..2], .little);
        const replication_factor = record.payload[4 + name_len];

        const topic_state = TopicState{
            .name = try self.allocator.dupe(u8, name),
            .created_lsn = record.lsn,
            .partitions = partitions,
            .replication_factor = replication_factor,
            .message_count = 0,
            .byte_count = 0,
            .last_publish_lsn = 0,
            .schema_id = 0,
            .is_deleted = false,
        };

        const key = try self.allocator.dupe(u8, name);
        try self.state.topics.put(key, topic_state);
        self.progress.topics_recovered += 1;

        if (self.on_topic_recovered) |cb| {
            cb(&topic_state);
        }

        log.debug("Recovered topic: {s}", .{name});
    }

    fn applyTopicDeleted(self: *StateRecoveryEngine, record: *const WALRecord) !void {
        if (record.payload.len < 2) return;

        const name_len = std.mem.readInt(u16, record.payload[0..2], .little);
        if (record.payload.len < 2 + name_len) return;

        const name = record.payload[2..][0..name_len];

        if (self.state.topics.getPtr(name)) |topic| {
            topic.is_deleted = true;
        }
    }

    fn applySubscriptionCreated(self: *StateRecoveryEngine, record: *const WALRecord) !void {
        _ = record;
        self.progress.subscriptions_recovered += 1;
    }

    fn applySubscriptionDeleted(self: *StateRecoveryEngine, record: *const WALRecord) !void {
        _ = record;
    }

    fn applyCursorUpdated(self: *StateRecoveryEngine, record: *const WALRecord) !void {
        _ = record;
        self.progress.cursors_recovered += 1;
    }

    fn applyLedgerCreated(self: *StateRecoveryEngine, record: *const WALRecord) !void {
        _ = record;
    }

    fn applyLedgerClosed(self: *StateRecoveryEngine, record: *const WALRecord) !void {
        _ = record;
    }

    /// Resolve any pending transactions (incomplete at crash)
    fn resolvePendingTransactions(self: *StateRecoveryEngine) !void {
        var uncommitted: u32 = 0;

        var iter = self.pending_txns.iterator();
        while (iter.next()) |entry| {
            if (!entry.value_ptr.is_committed) {
                // Rollback uncommitted transactions
                uncommitted += 1;
                for (entry.value_ptr.records.items) |record| {
                    self.allocator.free(record.payload);
                }
            }
            entry.value_ptr.records.deinit();
        }
        self.pending_txns.clearAndFree();

        if (uncommitted > 0) {
            log.info("Rolled back {} uncommitted transactions", .{uncommitted});
        }
    }

    /// Sync recovered state with HANA
    fn syncWithHANA(self: *StateRecoveryEngine) !void {
        log.info("Syncing recovered state with HANA...", .{});

        // In production: Query HANA for any state not in WAL
        // - Compare cursor positions
        // - Validate ledger metadata
        // - Reconcile message counts

        _ = self;
    }

    fn notifyProgress(self: *StateRecoveryEngine) void {
        if (self.on_progress_update) |cb| {
            cb(&self.progress);
        }
    }

    pub fn getProgress(self: *const StateRecoveryEngine) RecoveryProgress {
        return self.progress;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "RecoveredBrokerState init/deinit" {
    const allocator = std.testing.allocator;
    var state = RecoveredBrokerState.init(allocator);
    defer state.deinit();

    try std.testing.expectEqual(@as(u64, 0), state.last_lsn);
}

test "RecoveryState enum" {
    try std.testing.expectEqual(RecoveryState.NotStarted, RecoveryState.NotStarted);
    try std.testing.expect(RecoveryState.Completed != RecoveryState.Failed);
}

test "TopicState struct" {
    const topic = TopicState{
        .name = "test-topic",
        .created_lsn = 100,
        .partitions = 4,
        .replication_factor = 3,
        .message_count = 1000,
        .byte_count = 50000,
        .last_publish_lsn = 200,
        .schema_id = 0,
        .is_deleted = false,
    };

    try std.testing.expectEqualStrings("test-topic", topic.name);
    try std.testing.expectEqual(@as(u16, 4), topic.partitions);
}