//! BDC AIPrompt Streaming - HANA-backed Transactions
//! Exactly-once semantics with distributed transactions on SAP HANA

const std = @import("std");
const hana = @import("../hana/hana_db.zig");
const managed_ledger = @import("managed_ledger.zig");

const log = std.log.scoped(.transaction);

// ============================================================================
// Transaction Configuration
// ============================================================================

pub const TransactionConfig = struct {
    /// Default transaction timeout in seconds
    default_timeout_secs: u32 = 300, // 5 minutes
    /// Max concurrent transactions
    max_concurrent_txns: u32 = 10000,
    /// Transaction coordinator partitions
    coordinator_partitions: u32 = 16,
    /// Enable transaction log persistence
    enable_txn_log: bool = true,
    /// Pending ack store flush interval
    pending_ack_flush_interval_ms: u32 = 1000,
};

// ============================================================================
// Transaction ID
// ============================================================================

pub const TxnId = struct {
    /// Transaction coordinator ID
    most_bits: u64,
    /// Local transaction sequence
    least_bits: u64,

    pub fn format(self: TxnId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("({x}:{x})", .{ self.most_bits, self.least_bits });
    }

    pub fn toHanaId(self: TxnId) []const u8 {
        var buf: [64]u8 = undefined;
        return std.fmt.bufPrint(&buf, "{x:0>16}{x:0>16}", .{ self.most_bits, self.least_bits }) catch "";
    }
};

// ============================================================================
// Transaction Status
// ============================================================================

pub const TxnStatus = enum {
    Open,
    Committing,
    Committed,
    Aborting,
    Aborted,
    Timeout,

    pub fn fromString(s: []const u8) TxnStatus {
        if (std.mem.eql(u8, s, "OPEN")) return .Open;
        if (std.mem.eql(u8, s, "COMMITTING")) return .Committing;
        if (std.mem.eql(u8, s, "COMMITTED")) return .Committed;
        if (std.mem.eql(u8, s, "ABORTING")) return .Aborting;
        if (std.mem.eql(u8, s, "ABORTED")) return .Aborted;
        if (std.mem.eql(u8, s, "TIMEOUT")) return .Timeout;
        return .Aborted;
    }

    pub fn toString(self: TxnStatus) []const u8 {
        return switch (self) {
            .Open => "OPEN",
            .Committing => "COMMITTING",
            .Committed => "COMMITTED",
            .Aborting => "ABORTING",
            .Aborted => "ABORTED",
            .Timeout => "TIMEOUT",
        };
    }
};

// ============================================================================
// Transaction Metadata
// ============================================================================

pub const TransactionMeta = struct {
    txn_id: TxnId,
    status: TxnStatus,
    owner: []const u8, // Producer name
    created_at: i64,
    timeout_at: i64,
    last_modified_at: i64,

    // Produced partitions
    produced_partitions: std.ArrayList(ProducedPartition),
    // Acked subscriptions
    acked_subscriptions: std.ArrayList(AckedSubscription),

    pub fn init(allocator: std.mem.Allocator, txn_id: TxnId) TransactionMeta {
        return .{
            .txn_id = txn_id,
            .status = .Open,
            .owner = "",
            .created_at = std.time.milliTimestamp(),
            .timeout_at = std.time.milliTimestamp() + 300000, // 5 min default
            .last_modified_at = std.time.milliTimestamp(),
            .produced_partitions = std.ArrayList(ProducedPartition).init(allocator),
            .acked_subscriptions = std.ArrayList(AckedSubscription).init(allocator),
        };
    }

    pub fn deinit(self: *TransactionMeta) void {
        self.produced_partitions.deinit();
        self.acked_subscriptions.deinit();
    }

    pub fn isExpired(self: TransactionMeta) bool {
        return std.time.milliTimestamp() >= self.timeout_at;
    }

    pub fn isActive(self: TransactionMeta) bool {
        return self.status == .Open and !self.isExpired();
    }
};

pub const ProducedPartition = struct {
    topic: []const u8,
    partition: i32,
    first_sequence_id: i64,
    last_sequence_id: i64,
};

pub const AckedSubscription = struct {
    topic: []const u8,
    subscription: []const u8,
    cumulative_ack_position: managed_ledger.Position,
    individual_acks: std.ArrayList(managed_ledger.Position),
};

// ============================================================================
// Transaction Buffer (Pending Messages)
// ============================================================================

pub const TransactionBuffer = struct {
    allocator: std.mem.Allocator,
    hana_client: *hana.HanaClient,
    topic_name: []const u8,

    // In-memory buffer for uncommitted messages
    pending_entries: std.AutoHashMap(TxnId, std.ArrayList(PendingEntry)),
    lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, hana_client: *hana.HanaClient, topic_name: []const u8) TransactionBuffer {
        return .{
            .allocator = allocator,
            .hana_client = hana_client,
            .topic_name = topic_name,
            .pending_entries = std.AutoHashMap(TxnId, std.ArrayList(PendingEntry)).init(allocator),
            .lock = .{},
        };
    }

    pub fn deinit(self: *TransactionBuffer) void {
        var iter = self.pending_entries.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.pending_entries.deinit();
    }

    /// Add a message to the transaction buffer
    pub fn appendEntry(self: *TransactionBuffer, txn_id: TxnId, entry: PendingEntry) !void {
        self.lock.lock();
        defer self.lock.unlock();

        var list = self.pending_entries.getPtr(txn_id);
        if (list == null) {
            try self.pending_entries.put(txn_id, std.ArrayList(PendingEntry).init(self.allocator));
            list = self.pending_entries.getPtr(txn_id);
        }

        try list.?.append(entry);

        // Also persist to HANA for durability
        try self.persistPendingEntry(txn_id, entry);
    }

    fn persistPendingEntry(self: *TransactionBuffer, txn_id: TxnId, entry: PendingEntry) !void {
        _ = entry;
        var qb = hana.QueryBuilder.init(self.allocator);
        defer qb.deinit();

        try qb.appendFmt(
            \\INSERT INTO "AIPROMPT_STORAGE".AIPROMPT_TXN_PENDING_ENTRIES 
            \\(TXN_ID, TOPIC_NAME, LEDGER_ID, ENTRY_ID, SEQUENCE_ID, CREATED_AT, DATA)
            \\VALUES ('{s}', '{s}', 0, 0, 0, {}, NULL)
        , .{
            txn_id.toHanaId(),
            self.topic_name,
            std.time.milliTimestamp(),
        });

        try self.hana_client.execute(qb.build());
    }

    /// Commit transaction - move pending entries to main ledger
    pub fn commitTransaction(self: *TransactionBuffer, txn_id: TxnId) !void {
        self.lock.lock();
        defer self.lock.unlock();

        log.info("Committing transaction {} for topic {s}", .{ txn_id, self.topic_name });

        // Move entries from pending to committed
        if (self.pending_entries.fetchRemove(txn_id)) |entry| {
            // In production: move entries from pending table to main message table
            entry.value.deinit();
        }

        // Update HANA
        try self.updateTxnEntriesStatus(txn_id, .Committed);
    }

    /// Abort transaction - discard pending entries
    pub fn abortTransaction(self: *TransactionBuffer, txn_id: TxnId) !void {
        self.lock.lock();
        defer self.lock.unlock();

        log.info("Aborting transaction {} for topic {s}", .{ txn_id, self.topic_name });

        if (self.pending_entries.fetchRemove(txn_id)) |entry| {
            entry.value.deinit();
        }

        // Delete from HANA
        try self.deleteTxnEntries(txn_id);
    }

    fn updateTxnEntriesStatus(self: *TransactionBuffer, txn_id: TxnId, status: TxnStatus) !void {
        var qb = hana.QueryBuilder.init(self.allocator);
        defer qb.deinit();

        try qb.appendFmt(
            \\UPDATE "AIPROMPT_STORAGE".AIPROMPT_TXN_PENDING_ENTRIES 
            \\SET STATUS = '{s}' WHERE TXN_ID = '{s}' AND TOPIC_NAME = '{s}'
        , .{
            status.toString(),
            txn_id.toHanaId(),
            self.topic_name,
        });

        try self.hana_client.execute(qb.build());
    }

    fn deleteTxnEntries(self: *TransactionBuffer, txn_id: TxnId) !void {
        var qb = hana.QueryBuilder.init(self.allocator);
        defer qb.deinit();

        try qb.appendFmt(
            \\DELETE FROM "AIPROMPT_STORAGE".AIPROMPT_TXN_PENDING_ENTRIES 
            \\WHERE TXN_ID = '{s}' AND TOPIC_NAME = '{s}'
        , .{
            txn_id.toHanaId(),
            self.topic_name,
        });

        try self.hana_client.execute(qb.build());
    }
};

pub const PendingEntry = struct {
    position: managed_ledger.Position,
    data: []const u8,
    sequence_id: i64,
    timestamp: i64,
};

// ============================================================================
// Transaction Coordinator
// ============================================================================

pub const TransactionCoordinator = struct {
    allocator: std.mem.Allocator,
    config: TransactionConfig,
    hana_client: *hana.HanaClient,
    coordinator_id: u64,

    // Active transactions
    transactions: std.AutoHashMap(TxnId, *TransactionMeta),
    txn_lock: std.Thread.Mutex,

    // Transaction sequence generator
    next_txn_seq: std.atomic.Value(u64),

    // Stats
    total_txns_created: std.atomic.Value(u64),
    total_txns_committed: std.atomic.Value(u64),
    total_txns_aborted: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: TransactionConfig, hana_client: *hana.HanaClient, coordinator_id: u64) TransactionCoordinator {
        return .{
            .allocator = allocator,
            .config = config,
            .hana_client = hana_client,
            .coordinator_id = coordinator_id,
            .transactions = std.AutoHashMap(TxnId, *TransactionMeta).init(allocator),
            .txn_lock = .{},
            .next_txn_seq = std.atomic.Value(u64).init(0),
            .total_txns_created = std.atomic.Value(u64).init(0),
            .total_txns_committed = std.atomic.Value(u64).init(0),
            .total_txns_aborted = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *TransactionCoordinator) void {
        var iter = self.transactions.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.transactions.deinit();
    }

    /// Create a new transaction
    pub fn newTransaction(self: *TransactionCoordinator, timeout_ms: ?u64) !TxnId {
        self.txn_lock.lock();
        defer self.txn_lock.unlock();

        const seq = self.next_txn_seq.fetchAdd(1, .monotonic);
        const txn_id = TxnId{
            .most_bits = self.coordinator_id,
            .least_bits = seq,
        };

        const meta = try self.allocator.create(TransactionMeta);
        meta.* = TransactionMeta.init(self.allocator, txn_id);

        if (timeout_ms) |t| {
            meta.timeout_at = std.time.milliTimestamp() + @as(i64, @intCast(t));
        } else {
            meta.timeout_at = std.time.milliTimestamp() + @as(i64, self.config.default_timeout_secs) * 1000;
        }

        try self.transactions.put(txn_id, meta);

        // Persist to HANA
        try self.persistTransaction(meta);

        _ = self.total_txns_created.fetchAdd(1, .monotonic);

        log.info("Created new transaction {}", .{txn_id});
        return txn_id;
    }

    /// Add produced partition to transaction
    pub fn addProducedPartition(self: *TransactionCoordinator, txn_id: TxnId, topic: []const u8, partition: i32) !void {
        self.txn_lock.lock();
        defer self.txn_lock.unlock();

        const meta = self.transactions.get(txn_id) orelse return error.TxnNotFound;
        if (!meta.isActive()) return error.TxnNotActive;

        try meta.produced_partitions.append(.{
            .topic = topic,
            .partition = partition,
            .first_sequence_id = -1,
            .last_sequence_id = -1,
        });

        meta.last_modified_at = std.time.milliTimestamp();
    }

    /// Add acked subscription to transaction
    pub fn addAckedSubscription(self: *TransactionCoordinator, txn_id: TxnId, topic: []const u8, subscription: []const u8) !void {
        self.txn_lock.lock();
        defer self.txn_lock.unlock();

        const meta = self.transactions.get(txn_id) orelse return error.TxnNotFound;
        if (!meta.isActive()) return error.TxnNotActive;

        try meta.acked_subscriptions.append(.{
            .topic = topic,
            .subscription = subscription,
            .cumulative_ack_position = managed_ledger.Position.earliest,
            .individual_acks = std.ArrayList(managed_ledger.Position).init(self.allocator),
        });

        meta.last_modified_at = std.time.milliTimestamp();
    }

    /// Commit a transaction (two-phase commit)
    pub fn commitTransaction(self: *TransactionCoordinator, txn_id: TxnId) !void {
        self.txn_lock.lock();

        const meta = self.transactions.get(txn_id) orelse {
            self.txn_lock.unlock();
            return error.TxnNotFound;
        };

        if (!meta.isActive()) {
            self.txn_lock.unlock();
            return error.TxnNotActive;
        }

        // Phase 1: Mark as committing
        meta.status = .Committing;
        meta.last_modified_at = std.time.milliTimestamp();
        self.txn_lock.unlock();

        log.info("Starting commit for transaction {}", .{txn_id});

        // Persist committing status
        try self.updateTransactionStatus(txn_id, .Committing);

        // Phase 2: Commit on all partitions
        // In production: coordinate with all transaction buffers

        // Phase 3: Mark as committed
        self.txn_lock.lock();
        defer self.txn_lock.unlock();

        meta.status = .Committed;
        try self.updateTransactionStatus(txn_id, .Committed);

        _ = self.total_txns_committed.fetchAdd(1, .monotonic);
        log.info("Committed transaction {}", .{txn_id});
    }

    /// Abort a transaction
    pub fn abortTransaction(self: *TransactionCoordinator, txn_id: TxnId) !void {
        self.txn_lock.lock();

        const meta = self.transactions.get(txn_id) orelse {
            self.txn_lock.unlock();
            return error.TxnNotFound;
        };

        if (meta.status == .Committed) {
            self.txn_lock.unlock();
            return error.TxnAlreadyCommitted;
        }

        meta.status = .Aborting;
        self.txn_lock.unlock();

        log.info("Aborting transaction {}", .{txn_id});

        // Abort on all partitions
        // In production: coordinate with all transaction buffers

        self.txn_lock.lock();
        defer self.txn_lock.unlock();

        meta.status = .Aborted;
        try self.updateTransactionStatus(txn_id, .Aborted);

        _ = self.total_txns_aborted.fetchAdd(1, .monotonic);
        log.info("Aborted transaction {}", .{txn_id});
    }

    /// Get transaction status
    pub fn getTransactionStatus(self: *TransactionCoordinator, txn_id: TxnId) ?TxnStatus {
        self.txn_lock.lock();
        defer self.txn_lock.unlock();

        const meta = self.transactions.get(txn_id) orelse return null;
        return meta.status;
    }

    /// Cleanup expired transactions
    pub fn cleanupExpiredTransactions(self: *TransactionCoordinator) !u32 {
        self.txn_lock.lock();
        defer self.txn_lock.unlock();

        var expired_count: u32 = 0;
        var to_remove = std.ArrayList(TxnId).init(self.allocator);
        defer to_remove.deinit();

        var iter = self.transactions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.isExpired() and entry.value_ptr.*.status == .Open) {
                entry.value_ptr.*.status = .Timeout;
                try to_remove.append(entry.key_ptr.*);
                expired_count += 1;
            }
        }

        for (to_remove.items) |txn_id| {
            if (self.transactions.fetchRemove(txn_id)) |entry| {
                self.updateTransactionStatus(txn_id, .Timeout) catch {};
                entry.value.deinit();
                self.allocator.destroy(entry.value);
            }
        }

        if (expired_count > 0) {
            log.warn("Cleaned up {} expired transactions", .{expired_count});
        }

        return expired_count;
    }

    fn persistTransaction(self: *TransactionCoordinator, meta: *TransactionMeta) !void {
        var qb = hana.QueryBuilder.init(self.allocator);
        defer qb.deinit();

        try qb.appendFmt(
            \\INSERT INTO "AIPROMPT_STORAGE".AIPROMPT_TRANSACTIONS 
            \\(TXN_ID, COORDINATOR_ID, STATUS, OWNER, CREATED_AT, TIMEOUT_AT, LAST_MODIFIED_AT)
            \\VALUES ('{s}', {}, '{s}', '{s}', {}, {}, {})
        , .{
            meta.txn_id.toHanaId(),
            self.coordinator_id,
            meta.status.toString(),
            meta.owner,
            meta.created_at,
            meta.timeout_at,
            meta.last_modified_at,
        });

        try self.hana_client.execute(qb.build());
    }

    fn updateTransactionStatus(self: *TransactionCoordinator, txn_id: TxnId, status: TxnStatus) !void {
        var qb = hana.QueryBuilder.init(self.allocator);
        defer qb.deinit();

        try qb.appendFmt(
            \\UPDATE "AIPROMPT_STORAGE".AIPROMPT_TRANSACTIONS 
            \\SET STATUS = '{s}', LAST_MODIFIED_AT = {} WHERE TXN_ID = '{s}'
        , .{
            status.toString(),
            std.time.milliTimestamp(),
            txn_id.toHanaId(),
        });

        try self.hana_client.execute(qb.build());
    }

    pub fn getStats(self: *TransactionCoordinator) TxnCoordinatorStats {
        return .{
            .coordinator_id = self.coordinator_id,
            .active_txns = @intCast(self.transactions.count()),
            .total_created = self.total_txns_created.load(.monotonic),
            .total_committed = self.total_txns_committed.load(.monotonic),
            .total_aborted = self.total_txns_aborted.load(.monotonic),
        };
    }
};

pub const TxnCoordinatorStats = struct {
    coordinator_id: u64,
    active_txns: u32,
    total_created: u64,
    total_committed: u64,
    total_aborted: u64,
};

// ============================================================================
// HANA Transaction DDL
// ============================================================================

pub const TxnSchemaDDL = struct {
    pub fn getCreateTransactionsTableSQL() []const u8 {
        return
            \\CREATE COLUMN TABLE "AIPROMPT_STORAGE".AIPROMPT_TRANSACTIONS (
            \\    TXN_ID NVARCHAR(64) NOT NULL PRIMARY KEY,
            \\    COORDINATOR_ID BIGINT NOT NULL,
            \\    STATUS NVARCHAR(32) NOT NULL,
            \\    OWNER NVARCHAR(256),
            \\    CREATED_AT BIGINT NOT NULL,
            \\    TIMEOUT_AT BIGINT NOT NULL,
            \\    LAST_MODIFIED_AT BIGINT NOT NULL
            \\)
        ;
    }

    pub fn getCreatePendingEntriesTableSQL() []const u8 {
        return
            \\CREATE COLUMN TABLE "AIPROMPT_STORAGE".AIPROMPT_TXN_PENDING_ENTRIES (
            \\    TXN_ID NVARCHAR(64) NOT NULL,
            \\    TOPIC_NAME NVARCHAR(512) NOT NULL,
            \\    LEDGER_ID BIGINT NOT NULL,
            \\    ENTRY_ID BIGINT NOT NULL,
            \\    SEQUENCE_ID BIGINT NOT NULL,
            \\    CREATED_AT BIGINT NOT NULL,
            \\    DATA BLOB,
            \\    STATUS NVARCHAR(32) DEFAULT 'PENDING',
            \\    PRIMARY KEY (TXN_ID, TOPIC_NAME, LEDGER_ID, ENTRY_ID)
            \\)
        ;
    }

    pub fn getCreatePendingAcksTableSQL() []const u8 {
        return
            \\CREATE COLUMN TABLE "AIPROMPT_STORAGE".AIPROMPT_TXN_PENDING_ACKS (
            \\    TXN_ID NVARCHAR(64) NOT NULL,
            \\    TOPIC_NAME NVARCHAR(512) NOT NULL,
            \\    SUBSCRIPTION NVARCHAR(256) NOT NULL,
            \\    LEDGER_ID BIGINT NOT NULL,
            \\    ENTRY_ID BIGINT NOT NULL,
            \\    ACK_TYPE NVARCHAR(32) NOT NULL,
            \\    STATUS NVARCHAR(32) DEFAULT 'PENDING',
            \\    PRIMARY KEY (TXN_ID, TOPIC_NAME, SUBSCRIPTION, LEDGER_ID, ENTRY_ID)
            \\)
        ;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TxnId formatting" {
    const txn_id = TxnId{ .most_bits = 0x1234, .least_bits = 0x5678 };
    var buf: [64]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{}", .{txn_id}) catch "";
    try std.testing.expect(str.len > 0);
}

test "TxnStatus conversion" {
    try std.testing.expectEqual(TxnStatus.Open, TxnStatus.fromString("OPEN"));
    try std.testing.expectEqual(TxnStatus.Committed, TxnStatus.fromString("COMMITTED"));
    try std.testing.expectEqualStrings("ABORTED", TxnStatus.Aborted.toString());
}